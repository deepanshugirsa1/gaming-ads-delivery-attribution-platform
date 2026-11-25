-- Candidate touchpoints inside the *configured* reporting window, ranked so that
-- exactly one wins each conversion.
--
-- The priority order is the attribution rule, written once:
--   1. a click outranks a view, always. Someone who clicked and then converted is
--      a stronger claim than someone who merely saw the ad, even if the view came
--      later -- and without this rule a later banner view would steal credit from
--      the click that actually drove the visit.
--   2. among touchpoints of the same type, the most recent wins (last-touch).
--   3. ties break on touchpoint_id, so the model is deterministic. Without a final
--      tie-break, two runs over identical data can credit different campaigns,
--      which makes a reported number irreproducible and impossible to defend when
--      an advertiser disputes it.
--
-- A linear multi-touch credit is computed alongside, so the same table supports
-- both the reported last-touch number and a multi-touch comparison without a
-- second pass over the candidates.

{% set click_window = var('click_window_days') %}
{% set view_window = var('view_window_days') %}

with in_window as (
    select *
    from {{ ref('int_ads_conversion_candidates') }}
    where
        (touchpoint_type = 'click' and days_to_conversion <= {{ click_window }})
        or (touchpoint_type = 'view' and days_to_conversion <= {{ view_window }})
),

counted as (
    select
        *,
        count(*) over (partition by conversion_id) as candidate_touchpoint_count
    from in_window
),

ranked as (
    select
        *,
        row_number() over (
            partition by conversion_id
            order by
                case touchpoint_type when 'click' then 0 else 1 end asc,
                touchpoint_at desc,
                touchpoint_id asc
        ) as touchpoint_rank
    from counted
)

select
    conversion_id,
    user_id,
    advertiser_id,
    conversion_type,
    converted_at,
    converted_date,
    conversion_value_usd,
    touchpoint_type,
    touchpoint_id,
    impression_id,
    campaign_id,
    creative_id,
    placement,
    touchpoint_at,
    days_to_conversion,
    candidate_touchpoint_count,
    touchpoint_rank,
    touchpoint_rank = 1 as is_attributed_touchpoint,
    -- Linear multi-touch: every in-window touchpoint shares the conversion equally.
    -- Credits across one conversion always sum to exactly 1, which is the invariant
    -- the singular test on this model asserts.
    1.0 / candidate_touchpoint_count as linear_credit
from ranked
