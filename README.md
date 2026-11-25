# Gaming Platform Ads: Delivery, Attribution and ML Feature Pipeline

An advertising data platform built on top of a gaming-community product — ad auctions,
**rewarded quest** delivery and completion, conversion measurement reconciled against
third-party measurement partners, and the point-in-time feature and label tables a
ranking model trains on.

It runs on **dbt** against **BigQuery**, with **DuckDB** as a local target so the whole
project builds for free before it costs anything. Every model runs on both, unchanged.

The ad side sits on the engagement side rather than beside it. Users, servers, sessions
and messages are the context ads are targeted and ranked against, so `dim_users`,
`dim_servers` and `fct_user_engagement_daily` are upstream of the ranking features —
and a user's engagement history, as it stood before the ad request, is one of the
features the model learns from.

---

## What it models

**Rewarded quest completion.** The formats modelled here pay the user for engaging, and
what earns the reward differs: a seconds threshold for a rewarded video, full completion
for a reservation buy, accumulated minutes for a playtime quest. Milestones are stored
as events, so the warehouse answers *where people stop* rather than just how many
finished — and every rate is computed inside a format, never across them.

**Delivery.** An ad request is an opportunity to serve, logged whether or not anything
serves. Eligible campaigns bid, one wins, and the impression may still fail to render.
Requests, bids, impressions and clicks are each facts in their own right, so fill rate,
win rate and render failure are measurable instead of inferred from a gap between
tables.

**Conversion measurement.** First-party conversions are joined back to the touchpoints
that could have caused them, under configurable click-through and view-through windows,
with last-touch and linear multi-touch credit computed side by side. Conversions that
followed no ad at all stay uncredited, by design.

**Third-party reconciliation.** Two measurement-partner postback feeds — a mobile
install-attribution contract and a gaming engagement-measurement contract — arrive late,
sometimes twice, sometimes without a user identifier, and sometimes credit a different
campaign than we do. They are reported separately because they observe different things
and disagree at different rates. `mart_measurement_parity` reconciles the two
surfaces; `mart_mmp_surface_health` says whether a gap is a real attribution difference
or the partner's pipeline misbehaving.

**ML inputs.** Features and labels at bid grain — every candidate the auction
considered, not just the winners — built strictly from information available at request
time, with labels that mature at three different speeds and a training set that refuses
to pretend otherwise. Feature null rates, distributions and drift are monitored per day.

---

## The parts worth reading

Most of this repository is ordinary dbt. These are the decisions that took thinking,
and each is documented at the top of the model that implements it.

**Candidate touchpoints are collected at the widest window, not the reported one.**
`int_ads_conversion_candidates` gathers everything inside 28 days; the reported 7-day
number is a filter over it. So "what would our numbers look like on a 14-day window" is
a query, and `mart_attribution_window_sensitivity` answers it for every window at once.
Changing the window does not require reprocessing history.

**Attributed conversions are counted on the touchpoint date, not the conversion date.**
Spend happens when the ad serves. A Monday click converting on Thursday, booked on
Thursday, leaves Monday showing cost with no return and Thursday showing return with no
cost — and CPA and ROAS are then wrong on both days. The cost of aligning them is that
recent rows are incomplete, so `agg_campaign_performance_daily` carries
`is_window_closed` to say whether a row is final.

**Nothing in the feature tables can see its own outcome.** Every trailing aggregate
joins on `b.date < a.date`, strictly. The as-of tables expose no same-day column at all,
so they are structurally incapable of leaking the present — and
`assert_no_feature_leakage_on_campaign_first_day` checks that a campaign's first auction
shows no prior history, which is the signature leakage would leave.

**The three labels mature seconds, minutes and a week apart.** A bid from yesterday has
a conversion label of `false` meaning "not yet", not "never". Training on it teaches a
model that recent inventory never converts, which is self-reinforcing. `fct_ranking_labels`
computes maturity explicitly and a singular test enforces the arithmetic.

**Features are built at bid grain, not impression grain.** Training only on impressions
that served means learning only from ads the current ranker already preferred, and never
discovering that something it keeps rejecting would have performed well.

**Spend comes from two tables.** CPM campaigns bill on delivery, CPC campaigns bill on
the click. Summing only impressions understates every CPC campaign, consistently and
plausibly — so `assert_spend_reconciles_across_layers` reconciles spend between the fact
and the aggregate rather than merely checking it is non-negative.

**Parity compares like with like, or it compares nothing.** Both sides counted on the
conversion date, scope matched to mobile install and purchase, postbacks with no user
identifier held out as a known unknown. Get any of those wrong and the result is a
permanent 60% "coverage gap" that is pure scope mismatch, and someone spends a week
investigating it. A minimum-volume floor stops two conversions against three from being
reported as a 50% breach.

**Reserved inventory takes its slot, it does not outbid.** A reservation that merely bid
very high would appear in the bid landscape and distort every clearing-price statistic,
so it is modelled as priority. `mart_auction_landscape_daily` then cuts win rate by
advertiser tier, because when an auction opens to self-serve buyers the question that
decides whether the marketplace is healthy is whether small advertisers can win
anything.

**Bad data is flagged, never joined away.** Duplicate impressions are deduplicated in a
named model so the raw duplicate rate stays measurable. Orphan clicks — clicks whose
impression was never logged — are kept and flagged, because an inner join would make a
real tracking bug disappear from every number at once.

**Portability is enforced, not hoped for.** `cast(x as varchar)` runs on DuckDB and
fails on BigQuery. `EXTRACT(DAYOFWEEK)` runs on both and returns *different numbers*.
`scripts/lint_project.py` scans for every construct of that kind, then compiles all 70
SQL files through Jinja against both targets. Money uses a `decimal6()` macro because
DuckDB's bare `NUMERIC` is `DECIMAL(18,3)` and would round a $0.00420 CPM impression to
$0.004 — a 5% spend error appearing only on the local target.

---

## Data quality and observability

| Layer | What it catches |
|---|---|
| `scripts/validate_generated_data.py` | 24 checks on the generated feeds before the warehouse sees them: referential integrity, auction mechanics, targeting enforcement, and that every planted failure mode is actually present at its planted rate |
| dbt schema tests | uniqueness, nullability, referential integrity, accepted values, non-negativity |
| 14 singular tests | cross-model invariants: spend reconciliation, hourly against daily, one attributed touchpoint per conversion, multi-touch credit summing to one, cross-advertiser credit, window compliance, feature leakage, label maturity |
| `mart_ads_pipeline_health` | per-feed volume, duplicate rate and arrival lag against an SLA registry |
| `mart_ml_feature_health_daily` | per-feature null rate, distribution and drift against its own trailing baseline |
| `scripts/quality_gate.py` | ten gates over those marts plus dbt's own test results; writes a report and exits non-zero |
| `scripts/detect_anomalies.py` | robust anomaly detection on daily delivery series, weekday/weekend matched |
| `scripts/validate_attribution.py` | the derived attribution against generator ground truth, which the models cannot see |

A note on two of those, because the method matters more than the existence.

*Freshness is measured against the pipeline, not the clock.* The dataset is historical,
so a wall-clock freshness check marks everything permanently stale and the signal gets
ignored. "How far behind the rest of the pipeline is this feed" still has a useful
answer, and it keeps working during a backfill or a replay.

*Anomaly detection uses the median and a floored robust spread, not mean and standard
deviation.* The outlier being hunted is in the baseline, and one spike inflates a
standard deviation enough to hide itself. MAD alone turned out to be too noisy on a
30-point baseline — it underestimated the spread and produced a 0.6% false-alarm rate —
so the scale is the largest of MAD, IQR and a winsorized standard deviation, floored at
1% of the median. That measured 0.03% false alarms while planted anomalies still scored
above 11 against a threshold of 5. `--self-test` reproduces those numbers over 20
random series without needing a warehouse.

---

## What is real and what is not

Stated plainly, because a portfolio project that overstates itself is worse than one
that does less.

**Real and runnable.** The dbt project, every model and test, on DuckDB locally and on
BigQuery. The event generator. Every script in `scripts/`. The GitHub Actions workflow,
which runs all of it end to end.

**Synthetic.** All data. The generator produces it against the committed engagement
seeds, deterministically from `--seed`.

**Modelled on, not copied from.** The rewarded quest formats are modelled on *publicly
described* rewarded ad products — a seconds-threshold video, a completion-gated
reservation buy, playtime quests. Nothing here reflects any company's internal systems,
schemas or logic.

**Shaped like, not integrated with.** The two postback feeds are modelled on the shape of
published MMP contracts — late delivery, retransmission, identifier loss, attribution
disagreement. They are **not** an integration with AppsFlyer, Gamesight, Adjust, Singular
or any other vendor, and nothing here has ever talked to one. What the project
demonstrates is handling those contracts' failure modes.

**Scale.** Tens of millions of rows at `--scale 20`, measured. Not billions, and the
figures in this README are whatever the last run actually produced.

**Not yet verified.** `orchestration/definitions.py` is written against the dagster-dbt
API but has not been executed. It is excluded from CI and from every claim made here
until `dagster dev` has run it.

<!-- STATS:START -->
**Last `dbt build`** — not run yet. Run `dbt build --profiles-dir .` then `python scripts/update_readme_stats.py`.
<!-- STATS:END -->

---

## Running it

### Local, on DuckDB

```bash
pip install -r requirements.txt

python generate_events.py                      # engagement seeds (committed; optional)
python generate_ads_events.py --scale 4        # ad feeds -> data/ads/
python scripts/validate_generated_data.py      # check the feeds before building

dbt build --profiles-dir .                     # every model, seed and test

python scripts/validate_attribution.py         # derived attribution vs ground truth
python scripts/quality_gate.py                 # pipeline health gates
python scripts/detect_anomalies.py             # delivery anomalies
python scripts/update_readme_stats.py          # refresh the block above
```

`--scale 4` is a few minutes end to end. `--scale 20` gives tens of millions of rows for
a volume run; see `docs/06_bigquery_runbook.md` for what that costs on BigQuery's free
tier.

### On BigQuery

```bash
gcloud auth application-default login
export BIGQUERY_PROJECT=your-project-id

python generate_ads_events.py --scale 4
./scripts/load_bigquery.sh                     # explicit schemas from schemas/*.json
dbt build --profiles-dir . --target bigquery
```

Full walkthrough, cost estimates and the free-tier limits in
`docs/06_bigquery_runbook.md`.

---

## Layout

```
models/
  staging/            6 engagement + 9 ad feeds, typed and renamed, no business logic
  intermediate/       sessionization, deduplication, click validation, as-of aggregates,
                      attribution candidates and ranking
  marts/
    core/             dim_users, dim_servers, fct_events, fct_game_sessions
    metrics/          fct_user_engagement_daily, mart_server_health
    ads_core/         advertiser/campaign/creative/placement dims; request, bid,
                      impression, click, quest-completion, conversion,
                      attributed-conversion and postback facts
    ads_delivery/     hourly and daily delivery, campaign performance, rewarded-quest
                      funnel, budget pacing, auction landscape by advertiser tier
    ads_measurement/  parity, partner health, window sensitivity, multi-touch, pipeline health
    ads_ml/           ranking features, labels, training set, feature health, skew
macros/               cross-warehouse helpers: ads_raw, safe_div, pctl, decimal6
tests/                singular tests asserting cross-model invariants
scripts/              generation checks, lint, quality gate, anomaly detection,
                      attribution validation, BigQuery loader
schemas/              BigQuery JSON schema per feed: the data contract, committed
orchestration/        Dagster asset graph (not yet verified)
docs/                 metric definitions, attribution spec, ML spec, quality and SLA,
                      BigQuery runbook, full model walkthrough
```

---

## Documentation

| Document | What is in it |
|---|---|
| `docs/01_metric_definitions.md` | Engagement metrics: grain, logic, edge cases |
| `docs/02_roadmap.md` | Status and what comes next |
| `docs/03_attribution_spec.md` | Windows, priority rules, multi-touch, parity, and what attribution cannot answer |
| `docs/04_rewarded_quest_spec.md` | Reward rules per format, milestones, auction versus reserved inventory |
| `docs/05_ml_feature_spec.md` | Every feature, its as-of rule, label maturity, splitting |
| `docs/06_data_quality_and_sla.md` | Every check and threshold, and why each number was chosen |
| `docs/07_bigquery_runbook.md` | Running on BigQuery, free-tier cost, partitioning |
| `docs/08_model_walkthrough.md` | Every model in dependency order, plus the ten questions to answer cold |
