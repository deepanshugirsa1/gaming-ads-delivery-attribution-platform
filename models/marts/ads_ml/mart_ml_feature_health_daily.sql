-- Per-feature, per-day health of the ML inputs: completeness, distribution, and
-- drift against each feature's own trailing baseline.
--
-- This is the table that catches a model degrading before the model's metrics do.
-- When an upstream join quietly starts missing, a feature's null rate jumps while
-- every dbt test on the table still passes -- the rows are all there, they are just
-- empty. A ranker fed a silently-null engagement feature does not fail; it gets
-- worse, slowly, and nobody can say when it started.
--
-- Drift is measured against each feature's own trailing seven days rather than a
-- fixed expectation, because these distributions genuinely move -- a campaign
-- launch shifts them legitimately. Comparing a feature to its recent self separates
-- "the world changed" from "the pipeline changed", and only flags when the move is
-- large enough to matter.
--
-- Features are unpivoted with a union per feature rather than a pivot function, so
-- adding one is a single line in the list below and the SQL stays identical on both
-- warehouses.

{% set numeric_features = [
    'bid_cpm_usd',
    'predicted_ctr',
    'auction_bid_count',
    'request_hour',
    'account_age_days',
    'server_member_count',
    'user_prior_7d_messages_sent',
    'user_prior_7d_voice_minutes',
    'user_prior_7d_game_sessions',
    'user_prior_7d_active_days',
    'campaign_prior_7d_impressions',
    'campaign_prior_7d_clicks',
    'campaign_prior_7d_ctr',
    'campaign_prior_7d_rewards',
    'campaign_prior_7d_reward_rate',
    'reward_orbs',
    'completion_threshold_seconds',
    'required_playtime_minutes',
    'user_campaign_prior_7d_impressions',
    'user_campaign_prior_7d_exposure_days',
    'user_campaign_prior_7d_rewarded_quests'
] %}

with features as (
    select * from {{ ref('fct_ranking_features') }}
),

unpivoted as (
    {% for f in numeric_features %}
    select
        requested_date,
        '{{ f }}'                              as feature_name,
        cast({{ f }} as {{ decimal6() }})      as feature_value
    from features
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
),

daily as (
    select
        requested_date                                              as as_of_date,
        feature_name,
        count(*)                                                    as row_count,
        sum(case when feature_value is null then 1 else 0 end)      as null_count,
        {{ safe_div('sum(case when feature_value is null then 1 else 0 end)', 'count(*)') }}
            as null_rate,
        count(distinct feature_value)                               as distinct_values,
        avg(feature_value)                                          as mean_value,
        min(feature_value)                                          as min_value,
        max(feature_value)                                          as max_value,
        {{ pctl('feature_value', 0.50) }}                           as p50_value,
        {{ pctl('feature_value', 0.95) }}                           as p95_value,
        sum(case when feature_value = 0 then 1 else 0 end)          as zero_count
    from unpivoted
    group by 1, 2
),

baseline as (
    -- trailing seven days, strictly earlier, so a day is never compared to itself
    select
        a.as_of_date,
        a.feature_name,
        avg(b.mean_value)            as baseline_mean_value,
        avg(b.null_rate)             as baseline_null_rate,
        count(distinct b.as_of_date) as baseline_days
    from daily a
    left join daily b
        on  a.feature_name = b.feature_name
        and b.as_of_date < a.as_of_date
        and b.as_of_date >= {{ dbt.dateadd('day', -7, 'a.as_of_date') }}
    group by 1, 2
)

select
    d.as_of_date,
    d.feature_name,
    d.row_count,
    d.null_count,
    d.null_rate,
    d.zero_count,
    d.distinct_values,
    d.mean_value,
    d.min_value,
    d.max_value,
    d.p50_value,
    d.p95_value,

    b.baseline_mean_value,
    b.baseline_null_rate,
    b.baseline_days,
    {{ safe_div('d.mean_value - b.baseline_mean_value', 'abs(b.baseline_mean_value)') }} * 100
        as mean_drift_pct,

    -- A feature with no variation at all is usually a broken join or a constant that
    -- someone forgot to remove; either way it contributes nothing to a model and
    -- its presence suggests the pipeline is not doing what its author thinks.
    d.distinct_values <= 1 as is_constant,

    (d.null_rate > {{ var('feature_null_rate_threshold') }}) as is_null_rate_breach,
    (
        b.baseline_days >= 3
        and abs(
            {{ safe_div('d.mean_value - b.baseline_mean_value', 'abs(b.baseline_mean_value)') }} * 100
        ) > {{ var('feature_drift_threshold_pct') }}
    ) as is_drift_breach
from daily d
left join baseline b
    on d.as_of_date = b.as_of_date and d.feature_name = b.feature_name
