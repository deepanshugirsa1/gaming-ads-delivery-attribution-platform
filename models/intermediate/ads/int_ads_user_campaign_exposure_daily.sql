-- Impressions served to each user by each campaign per day.
--
-- The spine for creative fatigue: how often someone has already seen a campaign is
-- one of the strongest predictors of whether they will engage with it again, and
-- the effect is negative. Kept at daily grain so the trailing-window version below
-- can be built from strictly earlier days.

select
    i.user_id,
    i.campaign_id,
    i.impressed_date,
    count(*)                                             as impressions_served,
    sum(case when i.is_viewable then 1 else 0 end)       as viewable_impressions_served,
    -- Whether this user has previously finished a quest from this campaign is a
    -- stronger affinity signal than how many times they have merely seen it:
    -- completing a rewarded quest is a deliberate act, an impression is not.
    sum(case when q.was_rewarded then 1 else 0 end)      as rewarded_quests_served
from {{ ref('int_ads_impressions_deduped') }} i
left join {{ ref('int_ads_quest_outcomes') }} q
    on i.impression_id = q.impression_id
group by 1, 2, 3
