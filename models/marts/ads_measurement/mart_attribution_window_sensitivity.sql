-- How many conversions each attribution window would credit.
--
-- This table exists because "should the click window be 7 days or 28" is the most
-- expensive unanswerable question in ad measurement. Widening the window always
-- credits more conversions, which always makes campaigns look better, which is
-- exactly why the decision needs a number attached rather than a preference.
--
-- Every scenario is evaluated over the same candidate set collected at the widest
-- window, applying the identical ranking rule as the production model -- click
-- outranks view, then most recent, then deterministic tie-break. So the difference
-- between rows is the window alone, not a second implementation of attribution that
-- might have drifted from the first.
--
-- Scenarios come from the window_sensitivity_scenarios variable, so adding one is a
-- config change rather than new SQL.

{% set scenarios = var('window_sensitivity_scenarios') %}

with candidates as (
    select * from {{ ref('int_ads_conversion_candidates') }}
),

{% for s in scenarios %}
scenario_{{ loop.index }} as (
    select
        {{ s[0] }} as scenario_click_window_days,
        {{ s[1] }} as scenario_view_window_days,
        conversion_id,
        conversion_type,
        conversion_value_usd,
        campaign_id,
        touchpoint_type,
        days_to_conversion,
        row_number() over (
            partition by conversion_id
            order by
                case touchpoint_type when 'click' then 0 else 1 end asc,
                touchpoint_at desc,
                touchpoint_id asc
        ) as touchpoint_rank
    from candidates
    where (touchpoint_type = 'click' and days_to_conversion <= {{ s[0] }})
       or (touchpoint_type = 'view' and days_to_conversion <= {{ s[1] }})
),
{% endfor %}

attributed as (
    {% for s in scenarios %}
    select * from scenario_{{ loop.index }} where touchpoint_rank = 1
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
),

total_conversions as (
    select
        conversion_type,
        count(*)                  as conversions_total,
        sum(conversion_value_usd) as conversion_value_total_usd
    from {{ ref('fct_conversions') }}
    group by 1
)

select
    a.scenario_click_window_days,
    a.scenario_view_window_days,
    a.conversion_type,
    count(*)                                                     as attributed_conversions,
    sum(a.conversion_value_usd)                                  as attributed_value_usd,
    sum(case when a.touchpoint_type = 'click' then 1 else 0 end) as click_through_conversions,
    sum(case when a.touchpoint_type = 'view' then 1 else 0 end)  as view_through_conversions,
    count(distinct a.campaign_id)                                as campaigns_credited,
    avg(a.days_to_conversion)                                    as avg_days_to_conversion,
    {{ pctl('a.days_to_conversion', 0.95) }}                     as p95_days_to_conversion,

    t.conversions_total,
    -- Share of all conversions this window manages to credit. The remainder is
    -- organic demand plus exposures that fell outside the window, and the two
    -- cannot be separated by widening alone.
    {{ safe_div('count(*)', 't.conversions_total') }}             as attribution_coverage,

    -- Marked so a reader can tell at a glance which row is the number we publish.
    (a.scenario_click_window_days = {{ var('click_window_days') }}
     and a.scenario_view_window_days = {{ var('view_window_days') }}) as is_configured_window
from attributed a
left join total_conversions t on a.conversion_type = t.conversion_type
group by
    a.scenario_click_window_days,
    a.scenario_view_window_days,
    a.conversion_type,
    t.conversions_total
