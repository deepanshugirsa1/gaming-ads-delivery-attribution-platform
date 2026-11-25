-- One row per delivered impression, with how far into the quest the user got and
-- whether the reward was earned.
--
-- The canonical table for rewarded-format performance. Delivery tables answer how
-- many ads were shown; this answers how many were *finished*, which on a rewarded
-- product is the metric the advertiser is actually buying — and the one the
-- reservation formats are priced against.
--
-- Impressions with no milestone stream at all are kept, with did_start false. A
-- quest that never started is a delivery that produced nothing, and dropping those
-- rows would silently inflate every completion rate by shrinking the denominator.

with impressions as (
    select
        impression_id,
        request_id,
        campaign_id,
        creative_id,
        user_id,
        server_id,
        placement,
        impressed_at,
        impressed_date,
        total_spend_usd,
        is_clicked
    from {{ ref('fct_ad_impressions') }}
),

outcomes as (
    select * from {{ ref('int_ads_quest_outcomes') }}
),

campaigns as (
    select
        campaign_id,
        advertiser_id,
        quest_format,
        buying_model,
        reward_orbs,
        completion_threshold_seconds,
        required_playtime_minutes
    from {{ ref('stg_ads_campaigns') }}
),

creatives as (
    select creative_id, duration_sec
    from {{ ref('stg_ads_creatives') }}
)

select
    i.impression_id,
    i.request_id,
    i.campaign_id,
    c.advertiser_id,
    i.creative_id,
    i.user_id,
    i.server_id,
    i.placement,
    i.impressed_at,
    i.impressed_date,
    c.quest_format,
    c.buying_model,
    cr.duration_sec,

    coalesce(o.did_start, false)               as did_start,
    coalesce(o.reached_quartile_25, false)     as reached_quartile_25,
    coalesce(o.reached_quartile_50, false)     as reached_quartile_50,
    coalesce(o.reached_quartile_75, false)     as reached_quartile_75,
    coalesce(o.completed_view, false)          as completed_view,
    coalesce(o.met_playtime_threshold, false)  as met_playtime_threshold,
    coalesce(o.was_rewarded, false)            as was_rewarded,

    coalesce(o.seconds_viewed, 0)              as seconds_viewed,
    coalesce(o.playtime_minutes, 0)            as playtime_minutes,
    coalesce(o.progress_pct, 0)                as progress_pct,
    coalesce(o.orbs_granted, 0)                as orbs_granted,
    o.rewarded_at,
    case
        when o.rewarded_at is not null
        then {{ dbt.datediff('i.impressed_at', 'o.rewarded_at', 'second') }}
    end as seconds_to_reward,

    -- Which rule this impression had to satisfy, carried alongside the outcome so a
    -- reader never has to join back to the campaign to know why a 14-second view
    -- earned nothing while a 15-second one did.
    c.completion_threshold_seconds,
    c.required_playtime_minutes,
    c.reward_orbs                              as reward_orbs_offered,

    i.total_spend_usd,
    i.is_clicked
from impressions i
left join outcomes o on i.impression_id = o.impression_id
left join campaigns c on i.campaign_id = c.campaign_id
left join creatives cr on i.creative_id = cr.creative_id
