-- The rewarded-quest funnel by day, campaign, format and placement.
--
-- Rates are computed inside a format, never across formats. A reserve buy that pays
-- out only on full completion and a video quest that pays out at fifteen seconds
-- have completion rates that are not comparable numbers, and averaging them
-- produces a figure that describes nothing. Format is therefore in the grain, and
-- every rate below divides by a denominator from the same format.
--
-- Cost per reward is the number this product is really judged on: a rewarded format
-- buys attention outright, so what an advertiser pays per completed, rewarded quest
-- is the closest thing to a unit price.

with completions as (
    select * from {{ ref('fct_quest_completions') }}
),

campaigns as (
    select campaign_id, campaign_name, advertiser_id, objective
    from {{ ref('dim_campaigns') }}
),

rolled as (
    select
        impressed_date,
        campaign_id,
        quest_format,
        buying_model,
        placement,
        count(*)                                                      as impressions,
        sum(case when did_start then 1 else 0 end)                    as quest_starts,
        sum(case when reached_quartile_25 then 1 else 0 end)          as reached_q25,
        sum(case when reached_quartile_50 then 1 else 0 end)          as reached_q50,
        sum(case when reached_quartile_75 then 1 else 0 end)          as reached_q75,
        sum(case when completed_view then 1 else 0 end)               as completed_views,
        sum(case when met_playtime_threshold then 1 else 0 end)       as playtime_thresholds_met,
        sum(case when was_rewarded then 1 else 0 end)                 as rewards_granted,
        sum(orbs_granted)                                             as orbs_granted,
        sum(case when is_clicked then 1 else 0 end)                   as clicks,
        sum(total_spend_usd)                                          as total_spend_usd,
        avg(seconds_viewed)                                           as avg_seconds_viewed,
        avg(playtime_minutes)                                         as avg_playtime_minutes,
        avg(progress_pct)                                             as avg_progress_pct,
        avg(seconds_to_reward)                                        as avg_seconds_to_reward
    from completions
    group by 1, 2, 3, 4, 5
)

select
    r.impressed_date,
    r.campaign_id,
    c.campaign_name,
    c.advertiser_id,
    c.objective,
    r.quest_format,
    r.buying_model,
    r.placement,

    r.impressions,
    r.quest_starts,
    r.reached_q25,
    r.reached_q50,
    r.reached_q75,
    r.completed_views,
    r.playtime_thresholds_met,
    r.rewards_granted,
    r.orbs_granted,
    r.clicks,
    r.total_spend_usd,
    r.avg_seconds_viewed,
    r.avg_playtime_minutes,
    r.avg_progress_pct,
    r.avg_seconds_to_reward,

    {{ safe_div('r.quest_starts', 'r.impressions') }}        as start_rate,
    {{ safe_div('r.reached_q25', 'r.quest_starts') }}        as q25_rate,
    {{ safe_div('r.reached_q50', 'r.quest_starts') }}        as q50_rate,
    {{ safe_div('r.reached_q75', 'r.quest_starts') }}        as q75_rate,
    {{ safe_div('r.completed_views', 'r.quest_starts') }}    as view_completion_rate,
    {{ safe_div('r.rewards_granted', 'r.quest_starts') }}    as reward_rate,
    {{ safe_div('r.clicks', 'r.rewards_granted') }}          as post_reward_click_rate,

    -- The drop between the third quartile and completion is where a reserve buy
    -- loses its payout, so it is surfaced rather than left to be derived.
    r.reached_q75 - r.completed_views                        as abandoned_after_q75,

    {{ safe_div('r.total_spend_usd', 'r.rewards_granted') }}  as cost_per_reward_usd,
    {{ safe_div('r.total_spend_usd', 'r.completed_views') }}  as cost_per_completed_view_usd,
    {{ safe_div('r.total_spend_usd * 1000', 'r.impressions') }} as effective_cpm_usd
from rolled r
left join campaigns c on r.campaign_id = c.campaign_id
