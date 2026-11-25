{{ config(
    materialized = 'incremental',
    unique_key = 'bid_id',
    incremental_strategy = 'merge' if target.type == 'bigquery' else 'delete+insert',
    partition_by = {'field': 'requested_date', 'data_type': 'date'} if target.type == 'bigquery' else none,
    cluster_by = ['campaign_id'] if target.type == 'bigquery' else none
) }}

-- Ranking features, one row per bid: every (request, campaign) pair the auction
-- considered.
--
-- Grain is the bid and not the impression on purpose. A model trained only on
-- impressions that served learns from the ads the current ranker already preferred,
-- and can never discover that something it keeps rejecting would have performed
-- well. Training at candidate grain is what keeps the feedback loop open.
--
-- Every feature here is computable at request time. The three trailing tables this
-- joins are built from strictly earlier days, the campaign and creative attributes
-- are static, and the context columns come off the request itself. Nothing in this
-- table can see its own outcome -- which is the property that makes the training set
-- trustworthy, and the one that quietly breaks first when a feature gets added in a
-- hurry.
--
-- predicted_ctr is included and clearly named: it is the incumbent model's own
-- score, which was genuinely available at auction time and is a legitimate feature
-- for a successor model. It is also how a model inherits its predecessor's biases,
-- so it is flagged in the schema documentation rather than buried among the rest.

with bids as (
    select * from {{ ref('fct_ad_auction_bids') }}

    {% if is_incremental() %}
    where ingested_at >= (
        select coalesce(
            {{ dbt.dateadd('day', '-' ~ var('incremental_lookback_days'), 'max(ingested_at)') }},
            cast('1970-01-01' as timestamp)
        )
        from {{ this }}
    )
    {% endif %}
),

campaigns as (
    select
        campaign_id,
        advertiser_id,
        vertical,
        objective,
        quest_format,
        buying_model,
        reward_orbs,
        completion_threshold_seconds,
        required_playtime_minutes,
        bid_strategy,
        daily_budget_usd,
        is_unrestricted_targeting,
        target_country_count,
        target_platform_count,
        target_server_category_count,
        creative_count
    from {{ ref('dim_campaigns') }}
),

creatives as (
    select creative_id, creative_format, duration_sec
    from {{ ref('stg_ads_creatives') }}
),

servers as (
    select server_id, category as server_category, member_count as server_member_count
    from {{ ref('dim_servers') }}
),

users as (
    select user_id, signup_date, country as user_country, signup_platform
    from {{ ref('dim_users') }}
)

select
    b.bid_id,
    b.request_id,
    b.campaign_id,
    b.creative_id,
    b.user_id,
    b.server_id,
    b.requested_at,
    b.requested_date,

    -- ---------- auction context ----------
    b.bid_cpm_usd,
    b.predicted_ctr,
    b.auction_bid_count,
    b.is_winner,

    -- ---------- request context ----------
    b.placement,
    b.device_platform,
    b.country,
    extract(hour from b.requested_at) as request_hour,
    -- Day of week derived by counting days from a known Sunday and taking the
    -- remainder, rather than EXTRACT(DAYOFWEEK). BigQuery numbers the week from
    -- Sunday as 1 and DuckDB from Sunday as 0, so the obvious spelling would make
    -- the same feature take different values on the two warehouses -- a difference
    -- that would show up as unexplained drift when the target changed.
    mod({{ dbt.datediff("cast('2024-12-29' as date)", 'b.requested_date', 'day') }}, 7)
        as request_day_of_week,

    -- ---------- campaign and creative attributes ----------
    c.advertiser_id,
    c.vertical,
    c.objective,
    -- Quest format is the single most important categorical feature here: it
    -- determines what the user is being asked to do and what earns the reward, and
    -- the response curves for a fifteen-second video and a twenty-minute playtime
    -- quest have almost nothing in common.
    c.quest_format,
    c.buying_model,
    c.reward_orbs,
    c.completion_threshold_seconds,
    c.required_playtime_minutes,
    c.bid_strategy,
    c.daily_budget_usd,
    c.is_unrestricted_targeting,
    c.target_country_count,
    c.target_platform_count,
    c.target_server_category_count,
    c.creative_count,
    cr.creative_format,
    cr.duration_sec,

    -- ---------- server and user attributes ----------
    s.server_category,
    s.server_member_count,
    u.signup_platform,
    {{ dbt.datediff('u.signup_date', 'b.requested_date', 'day') }} as account_age_days,

    -- ---------- user engagement, as of the request day ----------
    coalesce(ue.prior_7d_messages_sent, 0)   as user_prior_7d_messages_sent,
    coalesce(ue.prior_7d_voice_minutes, 0)   as user_prior_7d_voice_minutes,
    coalesce(ue.prior_7d_game_sessions, 0)   as user_prior_7d_game_sessions,
    coalesce(ue.prior_7d_active_days, 0)     as user_prior_7d_active_days,

    -- ---------- campaign history, as of the request day ----------
    coalesce(cp.prior_7d_impressions, 0)     as campaign_prior_7d_impressions,
    coalesce(cp.prior_7d_clicks, 0)          as campaign_prior_7d_clicks,
    coalesce(cp.prior_7d_rewards, 0)         as campaign_prior_7d_rewards,
    -- Reward rate is left null for a cold-start campaign for the same reason CTR is:
    -- a campaign nobody has finished yet is unknown, not bad.
    cp.prior_7d_reward_rate                  as campaign_prior_7d_reward_rate,
    -- Left null deliberately for a campaign with no measured history. See
    -- int_ads_campaign_performance_asof: coalescing a cold start to zero teaches the
    -- model that new campaigns never get clicked.
    cp.prior_7d_ctr                          as campaign_prior_7d_ctr,

    -- ---------- creative fatigue, as of the request day ----------
    coalesce(ex.prior_7d_impressions, 0)        as user_campaign_prior_7d_impressions,
    coalesce(ex.prior_7d_exposure_days, 0)      as user_campaign_prior_7d_exposure_days,
    coalesce(ex.prior_7d_rewarded_quests, 0)    as user_campaign_prior_7d_rewarded_quests,
    coalesce(ex.prior_7d_impressions, 0) > 0    as user_has_seen_campaign,
    -- Having finished this advertiser's quest before is a deliberate act, and a far
    -- stronger affinity signal than repeated exposure. Kept separate from the
    -- fatigue count, which points the other way.
    coalesce(ex.prior_7d_rewarded_quests, 0) > 0 as user_has_completed_campaign_quest,

    b.ingested_at
from bids b
left join campaigns c on b.campaign_id = c.campaign_id
left join creatives cr on b.creative_id = cr.creative_id
left join servers s on b.server_id = s.server_id
left join users u on b.user_id = u.user_id
left join {{ ref('int_user_engagement_trailing_7d') }} ue
    on b.user_id = ue.user_id and b.requested_date = ue.as_of_date
left join {{ ref('int_ads_campaign_performance_asof') }} cp
    on b.campaign_id = cp.campaign_id and b.requested_date = cp.as_of_date
left join {{ ref('int_ads_user_campaign_exposure_trailing_7d') }} ex
    on b.user_id = ex.user_id
   and b.campaign_id = ex.campaign_id
   and b.requested_date = ex.as_of_date
