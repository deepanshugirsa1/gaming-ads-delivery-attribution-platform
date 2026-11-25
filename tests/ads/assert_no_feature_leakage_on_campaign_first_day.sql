-- On the first day a campaign ever served, its trailing history must be empty.
--
-- A direct test for point-in-time leakage. If the as-of join accidentally includes
-- same-day or later delivery, a campaign's very first auction will show prior
-- impressions it could not possibly have had -- and that is the signature of a
-- feature that will look excellent offline and useless in production.
with first_delivery as (
    select campaign_id, min(impressed_date) as first_impressed_date
    from {{ ref('fct_ad_impressions') }}
    group by 1
)
select
    f.bid_id,
    f.campaign_id,
    f.requested_date,
    d.first_impressed_date,
    f.campaign_prior_7d_impressions
from {{ ref('fct_ranking_features') }} f
join first_delivery d on f.campaign_id = d.campaign_id
where f.requested_date <= d.first_impressed_date
  and f.campaign_prior_7d_impressions > 0
