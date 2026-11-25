# Data Quality, SLAs and Observability

Four layers, each catching what the one before it cannot.

## 1. Before the warehouse — `scripts/validate_generated_data.py`

34 checks on the generated feeds: referential integrity, auction mechanics, targeting
enforcement, quest reward rules, reservation priority, and confirmation that **every
planted failure mode is present at its planted rate**.

That last part matters more than it looks. A test that passes because the bad data was
never generated is worse than no test — it reports health that was never exercised.

Rate checks compare against a **binomial band** (±4 standard errors), not a fixed
percentage. A planted 2% rate observed over 275 rows easily presents as 3.3% through
sampling alone; a fixed band fails for no reason at low volume and is far too loose at
high volume. The band tightens automatically as generated volume grows.

## 2. In the warehouse — dbt tests

Schema tests across every model: `unique`, `not_null`, `accepted_values`,
`relationships`, and a custom `non_negative`.

**18 singular tests** assert cross-model invariants that no column check can:

| Test | Catches |
|---|---|
| `assert_spend_reconciles_across_layers` | a rollup dropping or duplicating rows — every rate divides by spend, so one error makes CPM, CPC, CPA and ROAS wrong at once, plausibly |
| `assert_hourly_and_daily_delivery_agree` | the two surfaces most likely to be quoted at each other drifting after a late arrival |
| `assert_exactly_one_attributed_touchpoint` | a lost conversion, or a non-deterministic tie-break crediting two campaigns on two runs |
| `assert_linear_credit_sums_to_one` | inflated multi-touch totals that no row looks wrong in |
| `assert_attributed_campaign_belongs_to_advertiser` | billing one advertiser for another's result |
| `assert_attribution_respects_configured_window` | the 28-day candidate window leaking into the reported 7-day number |
| `assert_no_feature_leakage_on_campaign_first_day` | the as-of joins seeing the present |
| `assert_conversion_label_maturity_is_correct` | the guard that keeps immature labels out of training |
| `assert_reward_never_granted_below_threshold` | value given away that the advertiser did not buy |
| `assert_quest_funnel_is_monotonic` | milestones dropped or emitted out of order |
| `assert_reserved_inventory_never_loses_its_auction` | guaranteed delivery not delivered |
| `assert_every_impression_has_a_quest_row` | completion rates computed against a denominator that excludes the impressions that produced nothing |
| `assert_clicks_resolve_or_are_flagged` | orphan handling silently breaking |
| `assert_clicks_never_precede_impressions` | clock skew between collectors |
| `assert_impressions_never_exceed_requests` | deduplication failing |
| `assert_rates_are_bounded` | a join fanning out |
| `assert_every_bid_resolves_its_entities` | a dimension join failing, which surfaces as a silently null feature rather than a missing row |

## 3. Monitoring marts

- **`mart_ads_pipeline_health`** — per feed: volume, duplicate rate, arrival lag against
  an SLA registry, orphan click rate, conversions beyond the incremental lookback.
- **`mart_ml_feature_health_daily`** — per feature per day: null rate, distribution,
  drift, constant-value detection.
- **`mart_mmp_surface_health`** — per partner contract: retransmission rate, identifier
  loss, delivery lag, internally inconsistent claims.

**Freshness is measured against peer feeds, not the clock.** A wall-clock check marks
a historical extract stale forever. Comparing every feed to the single newest ingest
does the same thing, because conversions are allowed to land days later. A feed is
late when it falls behind the feeds with an equal or tighter SLA.

SLAs live in `source_freshness_registry` in `dbt_project.yml`, so renegotiating a
threshold is a config change with a visible diff.

## 4. Gates and detection

**`scripts/quality_gate.py`** — ten gates over the monitoring marts plus dbt's own
`run_results.json`. Error-level gates fail the build; warnings are recorded. `--self-test`
verifies the threshold logic against fixtures with no warehouse, because a gate that
silently always passes is worse than no gate.

**`scripts/detect_anomalies.py`** — daily delivery series, weekday matched to weekday.

Baseline is the median; spread is the **largest of MAD, IQR and a winsorized standard
deviation**, floored at 1% of the median. Mean and standard deviation are unusable here
because the outlier being hunted is in the baseline and one spike inflates the deviation
enough to hide itself. MAD alone proved too noisy on a 30-point baseline — it
underestimated spread and produced a 0.6% false-alarm rate. Taking the largest of three
estimators brought that to **0.03%** while planted anomalies still scored above 11
against a threshold of 5. Reproduce with `--self-test` over 20 random series.

**`scripts/validate_attribution.py`** — compares derived attribution against generator
ground truth the models cannot see. Perfect agreement would be the *wrong* result:
last-touch overriding the true cause, out-of-window exposures, and organic conversions
credited to ads are all correct behaviour. It fails only on disagreements the documented
rules cannot explain.

## Incremental lookback

`incremental_lookback_days` is 3, set from the **observed** arrival lag: conversions
arrive up to 72 hours late. A shorter lookback would permanently under-report and no test
on the latest partition would catch it, because the rows simply never arrive.
`fct_conversions.exceeded_incremental_lookback` flags anything that beat the window, so
the setting can be revisited from evidence rather than taste.
