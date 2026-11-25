-- A conversion must be credited to a campaign belonging to the advertiser the
-- conversion happened at. A cross-advertiser credit would bill one advertiser for
-- another's result, which is the single most damaging error this pipeline could make.
select
    a.conversion_id,
    a.advertiser_id      as conversion_advertiser_id,
    a.attributed_campaign_id,
    c.advertiser_id      as campaign_advertiser_id
from {{ ref('fct_attributed_conversions') }} a
join {{ ref('dim_campaigns') }} c on a.attributed_campaign_id = c.campaign_id
where a.is_attributed
  and a.advertiser_id <> c.advertiser_id
