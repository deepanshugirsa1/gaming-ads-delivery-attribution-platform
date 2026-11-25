-- One row per conversion, with the touchpoint that earned the credit, or an
-- explicit reason why nothing did.
--
-- Every conversion appears exactly once whether or not it was attributable. The
-- alternative -- an inner join to the winning touchpoint -- silently deletes
-- organic conversions and anything whose ad exposure fell outside the window, which
-- makes attributed conversions look like all conversions and inflates measured ad
-- effectiveness to 100%.
--
-- attribution_outcome separates the two reasons a conversion goes uncredited,
-- because they mean opposite things. 'no_touchpoint' is organic demand: the
-- advertiser earned it without us. 'touchpoint_outside_window' is a conversion that
-- did follow an ad, just not soon enough to count under the current window -- which
-- is an argument for a wider window, not evidence that the ad did nothing.

with conversions as (
    select * from {{ ref('fct_conversions') }}
),

winner as (
    select *
    from {{ ref('int_ads_attribution_ranked') }}
    where touchpoint_rank = 1
),

candidates as (
    select
        conversion_id,
        count(*)                   as wide_window_touchpoints,
        min(days_to_conversion)    as nearest_touchpoint_days
    from {{ ref('int_ads_conversion_candidates') }}
    group by 1
),

campaigns as (
    select campaign_id, campaign_name, objective, bid_strategy
    from {{ ref('stg_ads_campaigns') }}
)

select
    cv.conversion_id,
    cv.user_id,
    cv.advertiser_id,
    cv.conversion_type,
    cv.converted_at,
    cv.converted_date,
    cv.conversion_value_usd,
    cv.device_platform,
    cv.conversion_device_id,
    cv.had_observed_identity,
    cv.is_identity_recovered,
    cv.device_resolution_method,
    cv.ingest_lag_minutes,

    w.campaign_id            as attributed_campaign_id,
    c.campaign_name          as attributed_campaign_name,
    c.objective              as attributed_objective,
    w.creative_id            as attributed_creative_id,
    w.placement              as attributed_placement,
    w.touchpoint_type        as attribution_type,
    w.touchpoint_id          as attributed_touchpoint_id,
    w.impression_id          as attributed_impression_id,
    w.touchpoint_at          as attributed_touchpoint_at,
    w.days_to_conversion     as days_from_touchpoint_to_conversion,
    w.candidate_touchpoint_count as in_window_touchpoints,

    coalesce(cd.wide_window_touchpoints, 0) as wide_window_touchpoints,
    cd.nearest_touchpoint_days,

    w.conversion_id is not null as is_attributed,
    case
        when w.conversion_id is not null then 'attributed'
        when cd.conversion_id is not null then 'touchpoint_outside_window'
        else 'no_touchpoint'
    end as attribution_outcome,
    -- A conversion with several in-window touchpoints is one where last-touch and
    -- multi-touch will disagree. Counting them tells you how much the choice of
    -- attribution model actually matters before anyone argues about it.
    coalesce(w.candidate_touchpoint_count, 0) > 1 as is_multi_touch_path
from conversions cv
left join winner w on cv.conversion_id = w.conversion_id
left join candidates cd on cv.conversion_id = cd.conversion_id
left join campaigns c on w.campaign_id = c.campaign_id
