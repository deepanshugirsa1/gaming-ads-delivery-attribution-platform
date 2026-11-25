-- One row per advertiser, with lifetime delivery and conversion rollups.

with advertisers as (
    select * from {{ ref('stg_ads_advertisers') }}
),

campaigns as (
    select
        advertiser_id,
        count(*)                   as campaign_count,
        min(starts_at)             as first_campaign_started_at,
        max(ends_at)               as last_campaign_ends_at
    from {{ ref('stg_ads_campaigns') }}
    group by 1
),

conversions as (
    select
        advertiser_id,
        count(*)                        as lifetime_conversions,
        sum(conversion_value_usd)       as lifetime_conversion_value_usd
    from {{ ref('stg_ads_conversions') }}
    group by 1
)

select
    a.advertiser_id,
    a.advertiser_name,
    a.vertical,
    a.advertiser_tier,
    a.created_at,
    coalesce(c.campaign_count, 0)                  as campaign_count,
    c.first_campaign_started_at,
    c.last_campaign_ends_at,
    coalesce(v.lifetime_conversions, 0)            as lifetime_conversions,
    coalesce(v.lifetime_conversion_value_usd, 0)   as lifetime_conversion_value_usd
from advertisers a
left join campaigns c on a.advertiser_id = c.advertiser_id
left join conversions v on a.advertiser_id = v.advertiser_id
