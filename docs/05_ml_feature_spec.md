# ML Feature and Label Specification

## Grain: the bid, not the impression

`fct_ranking_features` has one row per **(request, campaign)** — every candidate the
auction considered, not only the winner.

Training only on impressions that served restricts the model to ads the current ranker
already preferred, and it can never learn that something it keeps rejecting would have
performed well. Candidate grain is what keeps that feedback loop open.

## The as-of rule

Every feature must be computable **at request time**. Three trailing tables supply the
history, and each joins on `b.date < a.date` — strictly less than:

| Table | Supplies |
|---|---|
| `int_user_engagement_trailing_7d` | prior messages, voice minutes, game sessions, active days |
| `int_ads_campaign_performance_asof` | prior impressions, clicks, CTR, rewards, reward rate |
| `int_ads_user_campaign_exposure_trailing_7d` | prior impressions, exposure days, rewarded quests |

Including the same day would let a feature count impressions served later that day —
possibly the very impression whose click is being predicted. That is label leakage: it
flatters every offline metric and vanishes in production, because at serving time the
rest of the day has not happened.

The as-of tables expose **no same-day column at all**, so they are structurally
incapable of leaking. `assert_no_feature_leakage_on_campaign_first_day` checks the
signature leakage would leave: a campaign's very first auction showing prior history.

All three are spined on **bids**, not on delivery. Keyed on days a campaign served, a
bid on a quiet day would find no row and read as unknown — so the feature would be
missing exactly for the low-delivery campaigns whose history matters most.

## Nulls that stay null

`campaign_prior_7d_ctr` and `campaign_prior_7d_reward_rate` are **null** for a campaign
with no measured history, not zero. A campaign nobody has clicked yet has no
click-through rate; calling it zero teaches the model that new campaigns never get
clicked, and new campaigns then never win the auctions that would prove otherwise.

## Feature groups

- **Auction context** — `bid_cpm_usd`, `predicted_ctr`, `auction_bid_count`
- **Request context** — placement, device platform, country, `request_hour`,
  `request_day_of_week`
- **Quest attributes** — `quest_format`, `buying_model`, `reward_orbs`,
  `completion_threshold_seconds`, `required_playtime_minutes`
- **Campaign attributes** — objective, bid strategy, budget, targeting breadth,
  creative count
- **User and server** — signup platform, `account_age_days`, server category and size
- **User history, as of** — prior 7d messages, voice minutes, game sessions, active days
- **Campaign history, as of** — prior 7d impressions, clicks, CTR, rewards, reward rate
- **Affinity and fatigue, as of** — prior 7d impressions to this user from this campaign
  (negative), prior rewarded quests from it (positive)

`predicted_ctr` is the incumbent ranker's own score. It was genuinely available at
auction time and is a legitimate feature — it is also how a successor inherits its
predecessor's biases, so it is named and documented rather than buried.

`request_day_of_week` is derived by counting days from a known Sunday and taking the
remainder, not `EXTRACT(DAYOFWEEK)`, which numbers the week from 1 on BigQuery and 0 on
DuckDB. The obvious spelling would make the same feature take different values per
warehouse and surface later as unexplained drift.

## Labels mature at three speeds

| Label | Final after |
|---|---|
| `was_served` | seconds |
| `was_clicked` | minutes |
| `was_attributed_conversion` | **up to `label_maturity_days` (7)** |

A bid from yesterday has a conversion label of `false` meaning *not yet*, not *never*.
Training on it teaches the model that recent inventory never converts — wrong, and
self-reinforcing, because the model then stops serving the inventory that would have.

`is_conversion_label_mature` is computed and exposed, checked by
`assert_conversion_label_maturity_is_correct`, because this is exactly the guard someone
removes to get more training data.

## Splitting

Time-based, never random. Rows on or after `holdout_start_date` are holdout.

Features are built from each user's and campaign's prior behaviour, so two bids from the
same user hours apart share almost all their feature values. A random split puts one in
train and one in holdout, the holdout score comes out flattering, and the model
disappoints in production.

`mart_ml_training_set` filters to rows where the **click** label is final and carries
conversion maturity as a column, so a CTR model can use every row while a conversion
model filters — rather than throwing away a week of good click data.

## Monitoring the inputs

`mart_ml_feature_health_daily` tracks, per feature per day: null rate, zero count,
distinct values, mean, min, max, p50, p95, and drift against that feature's **own**
trailing seven days. Comparing a feature to its recent self separates "the world
changed" from "the pipeline changed"; a fixed expectation would fire on every campaign
launch.

This catches the failure dbt tests cannot: an upstream join quietly starts missing, the
rows are all present but empty, every test passes, and the ranker gets worse slowly with
nobody able to say when it started.

`mart_ml_training_serving_skew` compares train against holdout distributions. Stated
limitation: with no live serving path it cannot catch skew caused by the serving code
computing a feature differently from the training code. That needs logged serving-time
feature values, and it is the next thing this project would add.
