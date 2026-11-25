-- How often a user had already seen a campaign, as of each day that campaign bid
-- for that user.
--
-- Creative fatigue: prior exposure is one of the strongest predictors of whether
-- someone engages again, and the effect is negative. Spined on the auction for the
-- same reason as the campaign history above -- a bid on a day with no prior exposure
-- needs a zero, not a missing row, and the difference between "zero impressions" and
-- "unknown" matters to a model.
--
-- `b.impressed_date < a.as_of_date` is strictly less than. Including the same day
-- would let the fatigue feature count impressions served later that day -- possibly
-- the very impression whose click is being predicted. That is label leakage: it
-- flatters every offline metric and disappears the moment the model is served live,
-- because at serving time the rest of the day has not happened yet.

with exposure_daily as (
    select * from {{ ref('int_ads_user_campaign_exposure_daily') }}
),

spine as (
    select distinct
        r.user_id,
        b.campaign_id,
        r.requested_date as as_of_date
    from {{ ref('stg_ads_auction_bids') }} b
    join {{ ref('stg_ads_requests') }} r
        on b.request_id = r.request_id
)

select
    s.user_id,
    s.campaign_id,
    s.as_of_date,
    coalesce(sum(e.impressions_served), 0)          as prior_7d_impressions,
    coalesce(sum(e.viewable_impressions_served), 0) as prior_7d_viewable_impressions,
    coalesce(sum(e.rewarded_quests_served), 0)      as prior_7d_rewarded_quests,
    count(distinct e.impressed_date)                as prior_7d_exposure_days
from spine s
left join exposure_daily e
    on  s.user_id = e.user_id
    and s.campaign_id = e.campaign_id
    and e.impressed_date < s.as_of_date
    and e.impressed_date >= {{ dbt.dateadd('day', -7, 's.as_of_date') }}
group by 1, 2, 3
