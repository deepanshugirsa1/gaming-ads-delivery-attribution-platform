-- The assembled ranking training set: features joined to labels, with the split.
--
-- Two deliberate choices.
--
-- The split is by time, never at random. Features are built from each user's and
-- campaign's prior behaviour, so two bids from the same user hours apart share
-- almost all of their feature values. A random split puts one in train and one in
-- holdout, the holdout score comes out flattering, and the model disappoints in
-- production. Splitting on a date boundary makes the holdout answer the question
-- that matters: given everything up to this date, how well do we do on what comes
-- next.
--
-- Rows are filtered to where the CLICK label is final, and conversion maturity is
-- carried as a column rather than used as a filter. The two labels mature a week
-- apart, so filtering everything to conversion maturity would throw away a week of
-- perfectly good click training data. A CTR model uses every row here; a conversion
-- model filters to is_conversion_label_mature, and the singular test enforces that
-- it did.

with features as (
    select * from {{ ref('fct_ranking_features') }}
),

labels as (
    select * from {{ ref('fct_ranking_labels') }}
),

reference as (
    select max(pipeline_as_of_date) as pipeline_as_of_date
    from {{ ref('fct_ranking_labels') }}
)

select
    f.bid_id,
    f.request_id,
    f.campaign_id,
    f.creative_id,
    f.user_id,
    f.requested_at,
    f.requested_date,

    -- ---------- features ----------
    f.bid_cpm_usd,
    f.predicted_ctr,
    f.auction_bid_count,
    f.placement,
    f.device_platform,
    f.country,
    f.request_hour,
    f.request_day_of_week,
    f.vertical,
    f.objective,
    f.quest_format,
    f.buying_model,
    f.reward_orbs,
    f.completion_threshold_seconds,
    f.required_playtime_minutes,
    f.bid_strategy,
    f.daily_budget_usd,
    f.is_unrestricted_targeting,
    f.target_country_count,
    f.target_platform_count,
    f.target_server_category_count,
    f.creative_count,
    f.creative_format,
    f.duration_sec,
    f.server_category,
    f.server_member_count,
    f.signup_platform,
    f.account_age_days,
    f.user_prior_7d_messages_sent,
    f.user_prior_7d_voice_minutes,
    f.user_prior_7d_game_sessions,
    f.user_prior_7d_active_days,
    f.campaign_prior_7d_impressions,
    f.campaign_prior_7d_clicks,
    f.campaign_prior_7d_ctr,
    f.campaign_prior_7d_rewards,
    f.campaign_prior_7d_reward_rate,
    f.user_campaign_prior_7d_impressions,
    f.user_campaign_prior_7d_exposure_days,
    f.user_campaign_prior_7d_rewarded_quests,
    f.user_has_seen_campaign,
    f.user_has_completed_campaign_quest,

    -- ---------- labels ----------
    l.was_served,
    l.was_clicked,
    l.was_attributed_conversion,
    l.attributed_conversions,
    l.attributed_conversion_value_usd,
    l.is_conversion_label_mature,
    l.conversion_label_matures_on,

    case
        when f.requested_date >= cast('{{ var("holdout_start_date") }}' as date) then 'holdout'
        else 'train'
    end as dataset_split,
    r.pipeline_as_of_date
from features f
join labels l on f.bid_id = l.bid_id
cross join reference r
-- the click label is final for any day that has fully closed
where f.requested_date < r.pipeline_as_of_date
