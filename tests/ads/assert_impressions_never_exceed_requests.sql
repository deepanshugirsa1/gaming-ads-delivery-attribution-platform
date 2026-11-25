-- Impressions on a day can never outnumber the ad requests that produced them.
-- If they do, deduplication has failed or impressions are being double-counted
-- somewhere between staging and the fact.
with requests as (
    select requested_date as activity_date, count(*) as requests
    from {{ ref('fct_ad_requests') }}
    group by 1
),
impressions as (
    select impressed_date as activity_date, count(*) as impressions
    from {{ ref('fct_ad_impressions') }}
    group by 1
)
select r.activity_date, r.requests, i.impressions
from requests r
join impressions i on r.activity_date = i.activity_date
where i.impressions > r.requests
