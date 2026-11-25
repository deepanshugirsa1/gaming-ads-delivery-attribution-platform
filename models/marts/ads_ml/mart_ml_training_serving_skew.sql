-- Feature distributions in the training window against the holdout window.
--
-- A stand-in for training/serving skew, and the honest version of it for a project
-- with no live serving path: the holdout window is the closest thing to "data the
-- model has not seen", so a feature whose distribution differs sharply between the
-- two is a feature that will behave differently in production than it did in
-- training.
--
-- Worth being clear about what this does and does not catch. It catches a feature
-- whose upstream definition changed partway through the window, a join that started
-- failing, or a seasonal shift large enough to matter. It cannot catch skew caused by
-- the serving path computing a feature differently from the training path, because
-- there is no serving path here -- that comparison needs logged serving-time feature
-- values, which is the next thing this project would need to add.

{% set numeric_features = [
    'bid_cpm_usd',
    'predicted_ctr',
    'auction_bid_count',
    'account_age_days',
    'user_prior_7d_messages_sent',
    'user_prior_7d_voice_minutes',
    'user_prior_7d_active_days',
    'campaign_prior_7d_impressions',
    'campaign_prior_7d_ctr',
    'campaign_prior_7d_reward_rate',
    'reward_orbs',
    'user_campaign_prior_7d_impressions',
    'user_campaign_prior_7d_rewarded_quests'
] %}

with training_set as (
    select * from {{ ref('mart_ml_training_set') }}
),

unpivoted as (
    {% for f in numeric_features %}
    select
        dataset_split,
        '{{ f }}'                           as feature_name,
        cast({{ f }} as {{ decimal6() }})   as feature_value
    from training_set
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
),

by_split as (
    select
        feature_name,
        dataset_split,
        count(*)                                                as row_count,
        {{ safe_div('sum(case when feature_value is null then 1 else 0 end)', 'count(*)') }}
            as null_rate,
        avg(feature_value)                                      as mean_value,
        {{ pctl('feature_value', 0.50) }}                       as p50_value,
        {{ pctl('feature_value', 0.95) }}                       as p95_value
    from unpivoted
    group by 1, 2
),

pivoted as (
    select
        feature_name,
        max(case when dataset_split = 'train' then row_count end)   as train_rows,
        max(case when dataset_split = 'holdout' then row_count end) as holdout_rows,
        max(case when dataset_split = 'train' then mean_value end)   as train_mean,
        max(case when dataset_split = 'holdout' then mean_value end) as holdout_mean,
        max(case when dataset_split = 'train' then p50_value end)    as train_p50,
        max(case when dataset_split = 'holdout' then p50_value end)  as holdout_p50,
        max(case when dataset_split = 'train' then p95_value end)    as train_p95,
        max(case when dataset_split = 'holdout' then p95_value end)  as holdout_p95,
        max(case when dataset_split = 'train' then null_rate end)    as train_null_rate,
        max(case when dataset_split = 'holdout' then null_rate end)  as holdout_null_rate
    from by_split
    group by 1
)

select
    feature_name,
    train_rows,
    holdout_rows,
    train_mean,
    holdout_mean,
    train_p50,
    holdout_p50,
    train_p95,
    holdout_p95,
    train_null_rate,
    holdout_null_rate,
    {{ safe_div('holdout_mean - train_mean', 'abs(train_mean)') }} * 100 as mean_shift_pct,
    {{ safe_div('holdout_p50 - train_p50', 'abs(train_p50)') }} * 100   as p50_shift_pct,
    coalesce(holdout_null_rate, 0) - coalesce(train_null_rate, 0)       as null_rate_shift,
    (
        abs({{ safe_div('holdout_mean - train_mean', 'abs(train_mean)') }} * 100)
            > {{ var('feature_drift_threshold_pct') }}
    ) as is_skew_breach
from pivoted
