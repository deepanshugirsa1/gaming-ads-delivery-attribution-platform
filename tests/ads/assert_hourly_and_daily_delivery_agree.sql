-- The hourly and daily delivery surfaces must report the same impressions and clicks
-- for the same day. They are the two tables most likely to be quoted at each other
-- in a meeting, and a late arrival landing in one but not the other is precisely how
-- they drift apart.
with hourly as (
    select impressed_date, sum(impressions) as impressions, sum(clicks) as clicks
    from {{ ref('agg_ad_delivery_hourly') }}
    group by 1
),
daily as (
    select impressed_date, sum(impressions) as impressions, sum(clicks) as clicks
    from {{ ref('agg_ad_delivery_daily') }}
    group by 1
)
select h.impressed_date, h.impressions as hourly_impressions, d.impressions as daily_impressions
from hourly h
join daily d on h.impressed_date = d.impressed_date
where h.impressions <> d.impressions or h.clicks <> d.clicks
