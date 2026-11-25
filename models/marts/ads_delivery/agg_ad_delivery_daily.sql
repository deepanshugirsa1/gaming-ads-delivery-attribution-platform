-- Delivery at (campaign, creative, placement, day) grain.
--
-- The everyday reporting table: fine enough to answer which creative is working on
-- which surface, coarse enough to read. Built from the hourly table rather than from
-- impressions again, so the two surfaces cannot disagree -- if daily recomputed from
-- source it would be possible for hourly and daily totals to diverge after a late
-- arrival, and an advertiser would eventually find the discrepancy before we did.

with hourly as (
    select * from {{ ref('agg_ad_delivery_hourly') }}
),

campaigns as (
    select campaign_id, campaign_name, advertiser_id, objective, bid_strategy
    from {{ ref('dim_campaigns') }}
),

creatives as (
    select creative_id, creative_format
    from {{ ref('dim_creatives') }}
),

rolled as (
    select
        campaign_id,
        creative_id,
        placement,
        impressed_date,
        sum(impressions)            as impressions,
        sum(viewable_impressions)   as viewable_impressions,
        sum(clicks)                 as clicks,
        sum(impression_spend_usd)   as impression_spend_usd,
        sum(click_spend_usd)        as click_spend_usd,
        sum(total_spend_usd)        as total_spend_usd,
        max(latest_ingested_at)     as latest_ingested_at
    from hourly
    group by 1, 2, 3, 4
)

select
    r.impressed_date,
    r.campaign_id,
    c.campaign_name,
    c.advertiser_id,
    c.objective,
    c.bid_strategy,
    r.creative_id,
    cr.creative_format,
    r.placement,
    r.impressions,
    r.viewable_impressions,
    r.clicks,
    r.impression_spend_usd,
    r.click_spend_usd,
    r.total_spend_usd,
    {{ safe_div('r.clicks', 'r.impressions') }}                  as ctr,
    {{ safe_div('r.viewable_impressions', 'r.impressions') }}    as viewable_rate,
    {{ safe_div('r.total_spend_usd * 1000', 'r.impressions') }}  as effective_cpm_usd,
    {{ safe_div('r.total_spend_usd', 'r.clicks') }}              as effective_cpc_usd,
    r.latest_ingested_at
from rolled r
left join campaigns c on r.campaign_id = c.campaign_id
left join creatives cr on r.creative_id = cr.creative_id
