-- Prior-7-day engagement per user, as of each day they were active.
--
-- This is the bridge between the two halves of the platform: engagement data
-- describes who the user is, and the ads ranking features need that description
-- as it stood *before* the ad request. Built from fct_user_engagement_daily so the
-- ads side inherits the governed DAU and voice-minute definitions rather than
-- recomputing activity its own way and disagreeing with the engagement dashboards.
--
-- Strictly-prior again: `b.activity_date < a.activity_date`. A request at 09:00
-- cannot know how many messages the user will send by 23:00, so neither can its
-- features.

with daily as (
    select * from {{ ref('fct_user_engagement_daily') }}
)

select
    a.user_id,
    a.activity_date                            as as_of_date,
    coalesce(sum(b.messages_sent), 0)          as prior_7d_messages_sent,
    coalesce(sum(b.voice_minutes), 0)          as prior_7d_voice_minutes,
    coalesce(sum(b.game_sessions), 0)          as prior_7d_game_sessions,
    count(distinct b.activity_date)            as prior_7d_active_days
from daily a
left join daily b
    on  a.user_id = b.user_id
    and b.activity_date < a.activity_date
    and b.activity_date >= {{ dbt.dateadd('day', -7, 'a.activity_date') }}
group by 1, 2
