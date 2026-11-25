-- Spend must agree between the impression fact and the daily aggregate.
--
-- A cross-layer reconciliation rather than a column check. Every rate in the
-- delivery marts divides by spend, so a rollup that drops or duplicates rows makes
-- CPM, CPC, CPA and ROAS all wrong at once, consistently, and in a way that looks
-- entirely plausible. Compared with a cent of tolerance for decimal rounding.
with fact as (
    select sum(total_spend_usd) as spend from {{ ref('fct_ad_impressions') }}
),
agg as (
    select sum(total_spend_usd) as spend from {{ ref('agg_ad_delivery_daily') }}
)
select f.spend as fact_spend, a.spend as agg_spend, f.spend - a.spend as difference
from fact f
cross join agg a
where abs(f.spend - a.spend) > 0.01
