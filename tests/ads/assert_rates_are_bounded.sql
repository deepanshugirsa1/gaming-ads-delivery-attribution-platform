-- Any rate expressed as a share must lie between zero and one. An out-of-range CTR
-- means a join is fanning out -- clicks counted against the wrong impressions -- and
-- it is the cheapest possible check for the most common modelling error there is.
select impressed_date, campaign_id, creative_id, placement, ctr, viewable_rate
from {{ ref('agg_ad_delivery_daily') }}
where ctr < 0 or ctr > 1 or viewable_rate < 0 or viewable_rate > 1
