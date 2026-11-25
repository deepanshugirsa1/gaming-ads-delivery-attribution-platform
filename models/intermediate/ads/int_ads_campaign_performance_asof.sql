-- Campaign delivery history as of each day a campaign bid, built only from
-- strictly earlier days.
--
-- Two things in here are easy to get wrong and expensive to discover later.
--
-- First, the spine comes from the auction, not from delivery. If it were keyed on
-- days the campaign served impressions, a bid on a day when the campaign happened
-- to serve nothing would find no row and its history would read as unknown -- so the
-- feature would be missing exactly for the low-delivery campaigns whose history
-- matters most. Keyed on bids, every bid gets a value.
--
-- Second, nothing same-day is exposed. The table holds strictly-prior aggregates and
-- nothing else, so it is structurally impossible to leak the present into a feature
-- built from it. A same-day column would be convenient and would eventually end up
-- in a training set, inflating offline metrics and collapsing in production.
--
-- prior_7d_ctr stays null for a campaign's first week rather than zero. A campaign
-- with no measured history has no click-through rate; calling it zero teaches a model
-- that new campaigns never get clicked, and new campaigns then never win the auctions
-- that would prove otherwise.

with daily as (
    select
        i.campaign_id,
        i.impressed_date                       as activity_date,
        count(*)                               as impressions,
        count(c.click_id)                      as clicks,
        sum(case when q.was_rewarded then 1 else 0 end) as rewards,
        sum(i.billable_amount_usd)             as impression_spend_usd
    from {{ ref('int_ads_impressions_deduped') }} i
    left join {{ ref('int_ads_clicks_validated') }} c
        on  i.impression_id = c.impression_id
        and not c.is_orphan
    left join {{ ref('int_ads_quest_outcomes') }} q
        on i.impression_id = q.impression_id
    group by 1, 2
),

spine as (
    select distinct
        b.campaign_id,
        r.requested_date as as_of_date
    from {{ ref('stg_ads_auction_bids') }} b
    join {{ ref('stg_ads_requests') }} r
        on b.request_id = r.request_id
),

trailing as (
    select
        s.campaign_id,
        s.as_of_date,
        sum(d.impressions)                 as prior_7d_impressions,
        sum(d.clicks)                      as prior_7d_clicks,
        sum(d.rewards)                     as prior_7d_rewards,
        sum(d.impression_spend_usd)         as prior_7d_impression_spend_usd,
        count(distinct d.activity_date)    as prior_7d_active_days
    from spine s
    left join daily d
        on  s.campaign_id = d.campaign_id
        and d.activity_date < s.as_of_date
        and d.activity_date >= {{ dbt.dateadd('day', -7, 's.as_of_date') }}
    group by 1, 2
)

select
    campaign_id,
    as_of_date,
    coalesce(prior_7d_impressions, 0)            as prior_7d_impressions,
    coalesce(prior_7d_clicks, 0)                 as prior_7d_clicks,
    coalesce(prior_7d_rewards, 0)                as prior_7d_rewards,
    coalesce(prior_7d_impression_spend_usd, 0)   as prior_7d_impression_spend_usd,
    prior_7d_active_days,
    {{ safe_div('prior_7d_clicks', 'prior_7d_impressions') }}   as prior_7d_ctr,
    -- How often this campaign's quest actually gets finished, as of this day. On a
    -- rewarded product this predicts the next impression's outcome better than CTR,
    -- because finishing is the behaviour the format is built to produce.
    {{ safe_div('prior_7d_rewards', 'prior_7d_impressions') }} as prior_7d_reward_rate
from trailing
