with source as (
    select * from {{ ads_raw('ads_quest_progress') }}
)

-- Milestone events inside a single rewarded quest: the view starting, each quartile
-- of a video reached, the view completing, a playtime threshold being met, and the
-- reward being granted.
--
-- These are events rather than columns on the impression because the question a
-- rewarded ad product actually has to answer is *where people stop*. A completion
-- flag tells you how many finished; a milestone stream tells you that half the
-- drop-off happens before the second quartile on one format and after the third on
-- another, which is the difference between a number and a decision.
select
    cast(progress_id as string)             as progress_id,
    cast(impression_id as string)           as impression_id,
    cast(user_id as string)                 as user_id,
    cast(campaign_id as string)             as campaign_id,
    cast(creative_id as string)             as creative_id,
    lower(cast(quest_format as string))     as quest_format,
    lower(cast(milestone as string))        as milestone,
    cast(seconds_viewed as int)             as seconds_viewed,
    cast(playtime_minutes as int)           as playtime_minutes,
    cast(progress_pct as {{ decimal6() }})  as progress_pct,
    cast(orbs_granted as int)               as orbs_granted,
    cast(occurred_ts as timestamp)          as occurred_at,
    cast(occurred_ts as date)               as occurred_date,
    cast(ingest_ts as timestamp)            as ingested_at
from source
