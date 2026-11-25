# Model Walkthrough

Every model in dependency order, in a sentence or two. If you cannot say this much
about a model from memory, you do not yet own it — and the point of this document is
that there is no model in the project you cannot account for.

---

## Staging — engagement (6)

Typed and renamed, no business logic. Timestamps end `_at`, dates `_date`, booleans
start `is_`.

- **`stg_users`** — one row per user: signup time, country, signup platform.
- **`stg_servers`** — one row per server: owner, creation time, category.
- **`stg_server_joins`** — one row per user-server join.
- **`stg_messages`** — one row per message, with character count.
- **`stg_voice_sessions`** — one row per voice session, duration derived.
- **`stg_game_session_events`** — raw start and end lifecycle events, unpaired.

## Staging — ads (10)

Read from the generated feeds through the `ads_raw()` macro: native tables on BigQuery,
gzipped CSV on DuckDB. CSV is read `all_varchar` and cast explicitly here, so both
warehouses produce identical types from identical files.

- **`stg_ads_advertisers`** — advertiser, vertical, and buying tier.
- **`stg_ads_campaigns`** — campaign with objective, quest format, buying model, reward
  rule, bid, budget, and targeting clauses left as raw text.
- **`stg_ads_creatives`** — creative, its quest format, and runtime for video formats.
- **`stg_ads_requests`** — one row per ad request: an opportunity to serve, logged
  whether or not anything served.
- **`stg_ads_auction_bids`** — every campaign that competed for every request. Booleans
  travel as 0/1 integers because BigQuery and DuckDB parse boolean CSV differently.
- **`stg_ads_impressions`** — impressions as logged, duplicates included on purpose.
- **`stg_ads_clicks`** — clicks as logged, including ones whose impression is unknown.
- **`stg_ads_conversions`** — first-party conversions, with arrival lag computed.
- **`stg_ads_quest_progress`** — milestone events inside a quest.
- **`stg_ads_mmp_postbacks`** — third-party claims. Every asserted field is prefixed
  `claimed_`, because this table is a partner's opinion, not a fact about our delivery.

## Intermediate — shared (3)

- **`int_game_sessions`** — pairs start and end events; sessions with no end are kept
  with `is_completed = false` rather than dropped by an inner join.
- **`int_user_activity_daily`** — the shared activity spine every engagement metric
  counts from, so DAU and retention cannot disagree.
- **`int_user_engagement_trailing_7d`** — prior-7-day engagement per user per day. The
  bridge between the engagement and ads halves; strictly prior days only.

## Intermediate — ads (9)

- **`int_ads_impressions_deduped`** — one row per `impression_id`, keeping the first
  delivery. Deduplication happens here, not in staging, so the raw duplicate rate stays
  measurable.
- **`int_ads_clicks_validated`** — every click, with orphans flagged rather than joined
  away. An inner join would make a real tracking bug vanish from every number.
- **`int_ads_mmp_postbacks_deduped`** — one row per `postback_id`, first receipt wins.
  Counting a retransmission twice looks like a measurement discrepancy, which is the
  most expensive kind of bug to chase.
- **`int_ads_quest_outcomes`** — collapses a milestone stream into one row per
  impression by conditional aggregation, so funnel and outcome cannot drift apart.
- **`int_ads_user_campaign_exposure_daily`** — impressions and rewarded quests per user,
  campaign and day.
- **`int_ads_user_campaign_exposure_trailing_7d`** — the prior-7-day version, spined on
  bids so every bid gets a value, strictly prior days only.
- **`int_ads_campaign_performance_asof`** — campaign history as of each auction day:
  prior impressions, clicks, CTR, rewards, reward rate. Exposes no same-day column, so
  it cannot leak.
- **`int_ads_conversion_candidates`** — every (conversion, touchpoint) pair inside the
  *widest* window, 28 days. Narrower windows are filters over this.
- **`int_ads_attribution_ranked`** — in-window candidates ranked so exactly one wins:
  click over view, then most recent, then a deterministic tie-break.

## Marts — engagement core and metrics (6)

- **`dim_users`**, **`dim_servers`** — entity dimensions with lifetime rollups.
- **`fct_events`** — all engagement events unioned to one grain.
- **`fct_game_sessions`** — one row per session with duration and completion.
- **`fct_user_engagement_daily`** — governed daily engagement, the canonical DAU source.
- **`mart_server_health`** — server-level engagement rollups.

## Marts — ads core (12)

- **`dim_advertisers`** — advertiser with tier and lifetime rollups.
- **`dim_campaigns`** — targeting clauses interpreted exactly once; item counts are null
  for an unrestricted clause because `ALL` is not a list of length one.
- **`dim_creatives`** — creative with lifetime delivery and CTR.
- **`dim_ad_placements`** — placement funnel from request to click.
- **`fct_ad_requests`** — the denominator table. Unfilled requests are first-class rows;
  a warehouse that stores only impressions can never explain the inventory it failed to
  sell. Separates "no eligible campaign" from "render failure" — different owners.
- **`fct_ad_auction_bids`** — the largest table and the grain features are built at.
- **`fct_ad_impressions`** — canonical impressions, deduplicated and enriched. Carries
  total spend from **both** billing paths, because CPM bills on delivery and CPC on the
  click.
- **`fct_ad_clicks`** — clicks with orphans flagged.
- **`fct_conversions`** — conversions before attribution. Separate on purpose: how many
  conversions happened is a fact; which ad earns credit is a modelling choice.
- **`fct_quest_completions`** — one row per impression with quest progress and whether
  the reward was earned. Impressions with no milestones are kept with
  `did_start = false`.
- **`fct_attributed_conversions`** — every conversion exactly once, attributed or not,
  with an explicit reason.
- **`fct_mmp_postbacks`** — deduplicated partner claims, each checked against what we
  know. Matching tolerates a minute of clock skew, because an exact-match join turns
  ordinary skew into a fake discrepancy.

## Marts — delivery (6)

- **`agg_ad_delivery_hourly`** — the low-latency surface. Deliberately carries no
  attributed conversions: mixing a metric final in minutes with one not final for a week
  gives readers a table that changes under them.
- **`agg_ad_delivery_daily`** — rolled up *from hourly*, not recomputed from source, so
  the two surfaces cannot disagree.
- **`agg_campaign_performance_daily`** — the funnel, spend and attributed outcomes.
  Conversions counted on the **touchpoint** date so cost and result share a row;
  `is_window_closed` says whether the row is final.
- **`agg_quest_funnel_daily`** — the rewarded funnel by format. Rates never cross
  formats.
- **`mart_budget_pacing_daily`** — spend against budget; reservations flagged, not mixed
  in.
- **`mart_auction_landscape_daily`** — win rate and bid landscape by advertiser tier.

## Marts — measurement (5)

- **`mart_measurement_parity`** — first-party against third-party per campaign-day, both
  counted on the conversion date, scope matched, unidentified postbacks held out.
- **`mart_mmp_surface_health`** — per partner contract: retransmission, identifier loss,
  lag, inconsistent claims. Says whether to investigate us or the vendor.
- **`mart_attribution_window_sensitivity`** — what every candidate window would credit,
  evaluated over one candidate set with the production ranking rule.
- **`mart_multi_touch_comparison`** — last-touch against linear credit per campaign.
- **`mart_ads_pipeline_health`** — per feed: volume, duplicates, lag against SLA.

## Marts — ML (5)

- **`fct_ranking_features`** — features at bid grain; every column computable at request
  time.
- **`fct_ranking_labels`** — three labels maturing at three speeds, with maturity stated.
- **`mart_ml_training_set`** — features joined to labels, split by time.
- **`mart_ml_feature_health_daily`** — per-feature completeness, distribution, drift.
- **`mart_ml_training_serving_skew`** — train against holdout distributions.

---

## The ten questions to be able to answer cold

1. **Why is the feature table at bid grain?** Training only on served impressions means
   learning only from ads the current ranker already liked.
2. **Where could this leak?** Every trailing join is `<`, strictly; the as-of tables
   expose no same-day column; a test checks a campaign's first auction shows no history.
3. **Why collect candidates at 28 days and report 7?** Window changes become a query
   instead of a reprocess, and the sensitivity mart can price every alternative.
4. **Why count conversions on the touchpoint date?** Otherwise spend and the result it
   produced land on different days and CPA and ROAS are wrong on both.
5. **Why keep orphan clicks?** An inner join makes a tracking bug disappear from every
   number at once.
6. **Why is spend in two tables?** CPM bills on delivery, CPC on the click; summing one
   understates every CPC campaign, plausibly.
7. **Why are format-level rates never averaged?** A reward at 15 seconds and a reward at
   full completion have incomparable denominators.
8. **Why is parity scope-matched?** Otherwise you report a permanent 60% coverage gap
   that is pure scope mismatch and somebody investigates it for a week.
9. **Why median and MAD for anomalies, and why three estimators?** The outlier is in the
   baseline; MAD alone was too noisy on a 30-point window and gave 0.6% false alarms,
   the max of three gave 0.03%.
10. **What can't this tell you?** Attribution cannot separate influence from
    coincidence. `validate_attribution.py` reports how often organic conversions get
    credited to ads, and only an experiment can resolve it.
