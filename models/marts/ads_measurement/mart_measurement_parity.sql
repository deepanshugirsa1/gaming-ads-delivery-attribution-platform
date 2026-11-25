-- First-party attribution against third-party claims, per campaign-day.
--
-- Three decisions make this comparison honest, and getting any of them wrong
-- produces a number that looks like a measurement finding but is an artefact.
--
-- 1. Both sides are counted on the date the conversion HAPPENED, not the date of
--    the touchpoint that earned it. The partner reports event dates and knows
--    nothing about our auctions, so touchpoint-dated first-party counts would be
--    comparing two different calendars.
--
-- 2. Scope is matched explicitly: mobile only, install and purchase only. That is
--    all the partner observes. Comparing their mobile installs against our
--    all-platform, all-event total would show a permanent 60% "undercount" that is
--    pure scope mismatch, and someone would spend a week investigating it.
--
-- 3. Postbacks with no usable user identifier are excluded from the comparison and
--    counted separately. They are real conversions the partner saw but cannot tie
--    to a user, so they belong in neither the matched nor the missing bucket --
--    they are a known unknown, and collapsing them into either side of the variance
--    makes the number mean something it does not.

{% set tolerance = var('parity_tolerance_pct') %}
{% set min_volume = var('min_conversions_for_parity_flag') %}

with first_party as (
    select
        attributed_campaign_id      as campaign_id,
        converted_date              as event_date,
        count(*)                    as first_party_conversions,
        sum(conversion_value_usd)   as first_party_value_usd
    from {{ ref('fct_attributed_conversions') }}
    where is_attributed
      and device_platform = 'mobile'
      and conversion_type in ('install', 'purchase')
    group by 1, 2
),

third_party as (
    select
        claimed_campaign_id         as campaign_id,
        event_date,
        count(*)                                                     as third_party_conversions,
        sum(claimed_value_usd)                                       as third_party_value_usd,
        sum(case when has_first_party_match then 1 else 0 end)        as matched_to_first_party,
        sum(case when is_third_party_only then 1 else 0 end)          as third_party_only,
        sum(case when has_advertiser_mismatch then 1 else 0 end)      as advertiser_mismatches
    from {{ ref('fct_mmp_postbacks') }}
    where not is_unidentified_user
      and event_name in ('install', 'purchase')
    group by 1, 2
),

unidentified as (
    select
        claimed_campaign_id as campaign_id,
        event_date,
        count(*)            as unidentified_postbacks
    from {{ ref('fct_mmp_postbacks') }}
    where is_unidentified_user
      and event_name in ('install', 'purchase')
    group by 1, 2
),

spine as (
    select campaign_id, event_date from first_party
    union
    select campaign_id, event_date from third_party
)

select
    s.event_date,
    s.campaign_id,
    c.campaign_name,
    c.advertiser_id,
    c.objective,

    coalesce(f.first_party_conversions, 0)   as first_party_conversions,
    coalesce(t.third_party_conversions, 0)   as third_party_conversions,
    coalesce(f.first_party_value_usd, 0)     as first_party_value_usd,
    coalesce(t.third_party_value_usd, 0)     as third_party_value_usd,
    coalesce(t.matched_to_first_party, 0)    as matched_to_first_party,
    coalesce(t.third_party_only, 0)          as third_party_only,
    coalesce(u.unidentified_postbacks, 0)    as unidentified_postbacks,
    coalesce(t.advertiser_mismatches, 0)     as advertiser_mismatches,

    coalesce(t.third_party_conversions, 0) - coalesce(f.first_party_conversions, 0)
        as conversion_variance,
    {{ safe_div(
        'coalesce(t.third_party_conversions, 0) - coalesce(f.first_party_conversions, 0)',
        'f.first_party_conversions'
    ) }} * 100 as conversion_variance_pct,

    -- Share of our attributed conversions the partner also saw and matched. The
    -- headline coverage number, and the one to watch for step changes after an SDK
    -- release or a platform privacy change.
    {{ safe_div('t.matched_to_first_party', 'f.first_party_conversions') }} as match_rate,

    greatest(coalesce(f.first_party_conversions, 0), coalesce(t.third_party_conversions, 0))
        as comparison_volume,
    greatest(coalesce(f.first_party_conversions, 0), coalesce(t.third_party_conversions, 0))
        >= {{ min_volume }} as has_sufficient_volume,

    -- Flagged only when the gap is both material and resting on enough volume to
    -- mean something.
    (
        greatest(coalesce(f.first_party_conversions, 0), coalesce(t.third_party_conversions, 0))
            >= {{ min_volume }}
        and abs(
            {{ safe_div(
                'coalesce(t.third_party_conversions, 0) - coalesce(f.first_party_conversions, 0)',
                'f.first_party_conversions'
            ) }} * 100
        ) > {{ tolerance }}
    ) as is_parity_breach
from spine s
left join first_party f on s.campaign_id = f.campaign_id and s.event_date = f.event_date
left join third_party t on s.campaign_id = t.campaign_id and s.event_date = t.event_date
left join unidentified u on s.campaign_id = u.campaign_id and s.event_date = u.event_date
left join {{ ref('dim_campaigns') }} c on s.campaign_id = c.campaign_id
