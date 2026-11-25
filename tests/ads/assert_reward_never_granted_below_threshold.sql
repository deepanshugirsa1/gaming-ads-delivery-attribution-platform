-- A reward may only be granted once its format's rule is satisfied: a seconds
-- threshold for a video quest, full completion for a reserve buy, accumulated
-- minutes for a play or arena quest.
--
-- This is the integrity check the whole rewarded product rests on. A reward granted
-- early is value given away that the advertiser did not buy; granted late, it is a
-- user who earned nothing for finishing. Both are visible to users immediately and
-- to finance eventually.
select
    impression_id,
    quest_format,
    seconds_viewed,
    playtime_minutes,
    completion_threshold_seconds,
    required_playtime_minutes,
    duration_sec
from {{ ref('fct_quest_completions') }}
where was_rewarded
  and (
        (quest_format = 'video_quest' and seconds_viewed < completion_threshold_seconds)
     or (quest_format = 'video_quest_reserve' and seconds_viewed < duration_sec)
     or (quest_format in ('play_quest', 'arena_quest')
         and playtime_minutes < required_playtime_minutes)
  )
