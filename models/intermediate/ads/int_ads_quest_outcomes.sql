-- One row per impression, collapsing its milestone stream into the outcome.
--
-- Built by conditional aggregation over the events rather than by reading a flag,
-- so the outcome and the funnel can never disagree: if a reward row exists the
-- impression is rewarded, and if it does not, it is not. There is no second source
-- of truth to drift.
--
-- Note what is deliberately absent: a single "completion rate" column. Completion
-- means a different thing per format -- a seconds threshold, a full view, or
-- accumulated minutes -- so collapsing them here would produce an average across
-- incomparable denominators. The format-aware rates are computed downstream where
-- the format is in the grain.

with progress as (
    select * from {{ ref('stg_ads_quest_progress') }}
)

select
    impression_id,
    max(campaign_id)                        as campaign_id,
    max(creative_id)                        as creative_id,
    max(user_id)                            as user_id,
    max(quest_format)                       as quest_format,

    max(seconds_viewed)                     as seconds_viewed,
    max(playtime_minutes)                   as playtime_minutes,
    max(progress_pct)                       as progress_pct,
    max(orbs_granted)                       as orbs_granted,

    max(case when milestone in ('view_start', 'play_start') then 1 else 0 end) = 1
        as did_start,
    max(case when milestone = 'quartile_25' then 1 else 0 end) = 1  as reached_quartile_25,
    max(case when milestone = 'quartile_50' then 1 else 0 end) = 1  as reached_quartile_50,
    max(case when milestone = 'quartile_75' then 1 else 0 end) = 1  as reached_quartile_75,
    max(case when milestone = 'view_complete' then 1 else 0 end) = 1 as completed_view,
    max(case when milestone = 'playtime_threshold' then 1 else 0 end) = 1
        as met_playtime_threshold,
    max(case when milestone = 'reward_granted' then 1 else 0 end) = 1 as was_rewarded,

    min(occurred_at)                        as first_milestone_at,
    max(case when milestone = 'reward_granted' then occurred_at end) as rewarded_at,
    count(*)                                as milestone_count,
    max(ingested_at)                        as ingested_at
from progress
group by 1
