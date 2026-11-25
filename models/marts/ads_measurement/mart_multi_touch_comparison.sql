-- Last-touch credit against linear multi-touch credit, per campaign.
--
-- Last-touch is what gets reported, because it is simple to explain and impossible
-- to argue with. It also systematically over-credits whatever ran closest to the
-- conversion and under-credits everything that introduced the user earlier.
--
-- This table quantifies that bias for each campaign so the reporting choice is
-- visible rather than assumed. A campaign whose linear credit materially exceeds its
-- last-touch credit is doing upper-funnel work that last-touch reporting hides --
-- and it is usually the campaign someone is about to cut for poor performance.

with ranked as (
    select * from {{ ref('int_ads_attribution_ranked') }}
),

last_touch as (
    select
        campaign_id,
        count(*)                    as last_touch_conversions,
        sum(conversion_value_usd)   as last_touch_value_usd
    from ranked
    where touchpoint_rank = 1
    group by 1
),

linear as (
    select
        campaign_id,
        sum(linear_credit)                                as linear_conversions,
        sum(linear_credit * conversion_value_usd)         as linear_value_usd,
        count(*)                                          as touchpoints_in_paths,
        count(distinct conversion_id)                     as conversions_touched
    from ranked
    group by 1
)

select
    coalesce(l.campaign_id, n.campaign_id)       as campaign_id,
    c.campaign_name,
    c.objective,
    c.bid_strategy,
    coalesce(l.last_touch_conversions, 0)        as last_touch_conversions,
    coalesce(n.linear_conversions, 0)            as linear_conversions,
    coalesce(l.last_touch_value_usd, 0)          as last_touch_value_usd,
    coalesce(n.linear_value_usd, 0)              as linear_value_usd,
    coalesce(n.conversions_touched, 0)           as conversions_touched,
    coalesce(n.touchpoints_in_paths, 0)          as touchpoints_in_paths,

    coalesce(n.linear_conversions, 0) - coalesce(l.last_touch_conversions, 0)
        as credit_shift_conversions,
    {{ safe_div(
        'coalesce(n.linear_conversions, 0) - coalesce(l.last_touch_conversions, 0)',
        'l.last_touch_conversions'
    ) }} * 100 as credit_shift_pct,

    -- True when multi-touch would credit this campaign more than last-touch does:
    -- the campaign is appearing in conversion paths without closing them.
    coalesce(n.linear_conversions, 0) > coalesce(l.last_touch_conversions, 0)
        as is_undercredited_by_last_touch
from last_touch l
full outer join linear n on l.campaign_id = n.campaign_id
left join {{ ref('dim_campaigns') }} c
    on coalesce(l.campaign_id, n.campaign_id) = c.campaign_id
