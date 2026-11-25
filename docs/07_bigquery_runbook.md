# BigQuery Runbook

The project develops on DuckDB and targets BigQuery. The same models run on both; only
the profile differs.

## One-time setup

```bash
gcloud auth application-default login
export BIGQUERY_PROJECT=your-project-id
export BIGQUERY_DATASET=gaming_ads_platform     # optional, this is the default
export BIGQUERY_LOCATION=US                     # optional
```

`profiles.yml` reads these from the environment, so no project id or credential is ever
committed. A service-account alternative is in `profiles.example.yml` for CI.

## Load and build

```bash
python generate_ads_events.py --scale 4
python scripts/validate_generated_data.py
./scripts/load_bigquery.sh
dbt build --profiles-dir . --target bigquery
python scripts/validate_attribution.py
python scripts/quality_gate.py
python scripts/detect_anomalies.py
python scripts/update_readme_stats.py
```

The engagement seeds load through `dbt seed` as part of `dbt build`. The ad feeds are
too large for version control, so they are generated to `data/ads/` and loaded by
`load_bigquery.sh` with **explicit JSON schemas** from `schemas/`, written by the
generator from the same definition that produced the CSV. Not `--autodetect`:
autodetect samples rows, so a column that is null for the first few thousand rows can
be typed differently between loads, and a NUMERIC that silently becomes STRING turns
every spend aggregate into a cast error or a wrong number.

`load_bigquery.sh` uses `--replace`, so a reload is idempotent. These are full
snapshots of a generated run; appending would double every row on a second run.

## Cost

BigQuery's free tier gives 10 GB storage and 1 TB of query processing per month.

| Scale | Approx rows | Approx storage |
|---|---|---|
| `--scale 1` | ~2.8M | ~40 MB |
| `--scale 4` | ~11M | ~160 MB |
| `--scale 20` | ~55M | ~800 MB |

A full `dbt build` scans a few GB at scale 4, so dozens of builds fit inside the free
monthly allowance. `maximum_bytes_billed` is set to 100 GB in the profile as a
backstop against a runaway query quietly spending the tier.

## Partitioning and clustering

Incremental models are partitioned on their event date and clustered on the columns
delivery queries filter by:

| Model | Partition | Cluster |
|---|---|---|
| `fct_ad_requests` | `requested_date` | `placement`, `country` |
| `fct_ad_auction_bids` | `requested_date` | `campaign_id` |
| `fct_ad_impressions` | `impressed_date` | `campaign_id`, `placement` |
| `fct_ad_clicks` | `clicked_date` | `campaign_id` |
| `fct_conversions` | `converted_date` | `advertiser_id`, `conversion_type` |
| `agg_ad_delivery_hourly` | `impressed_date` | `campaign_id` |
| `fct_ranking_features` | `requested_date` | `campaign_id` |

These are applied only when `target.type == 'bigquery'`; DuckDB ignores them.

Incremental strategy is `merge` on BigQuery and `delete+insert` on DuckDB, set
explicitly per target rather than relying on each adapter's default.

## Incremental behaviour

Incremental models filter on **ingest** time with a three-day lookback, not event time.
An event that arrives late still has to land; filtering on event date would permanently
skip anything delivered after its own day closed. Whole hours and days are recomputed
and merged rather than appended, so a late arrival corrects its bucket instead of
creating a second row for it.

To rebuild from scratch: `dbt build --profiles-dir . --target bigquery --full-refresh`.

## Portability rules worth knowing

`scripts/lint_project.py` enforces these; it runs first in CI.

- `cast(x as string)`, never `varchar` — BigQuery has no VARCHAR.
- `{{ dbt.datediff }}`, `{{ dbt.dateadd }}`, `{{ dbt.date_trunc }}` — `DATE_TRUNC` takes
  a DATE on BigQuery and timestamps need `TIMESTAMP_TRUNC`.
- Never `EXTRACT(DAYOFWEEK)` — it returns *different numbers* on the two warehouses.
- `{{ decimal6() }}` for money and rates — DuckDB's bare `NUMERIC` is `DECIMAL(18,3)`
  and would round a $0.00420 CPM impression to $0.004, a 5% spend error appearing only
  on the local target.
- `{{ safe_div() }}` for every rate — BigQuery raises on division by zero, DuckDB does
  not, and a rate with no denominator is unknown rather than zero.
