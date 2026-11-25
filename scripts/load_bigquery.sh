#!/usr/bin/env bash
# Load the generated ad feeds into BigQuery with explicit schemas.
#
# Explicit schemas, not --autodetect. Autodetect samples rows, so a column that is
# null for the first few thousand rows (claimed_user_id, say) can be typed differently
# from one load to the next -- and a column that silently becomes STRING instead of
# NUMERIC turns every spend aggregate into a cast error or, worse, a wrong number.
# schemas/*.json is written by the generator from the same definition that produced the
# CSV, so the file and the table cannot disagree.
#
# Usage:
#   export BIGQUERY_PROJECT=your-project
#   export BIGQUERY_LOCATION=US          # optional, defaults to US
#   ./scripts/load_bigquery.sh
#
# Requires: the bq CLI, authenticated (`gcloud auth login` and
# `gcloud auth application-default login`).

set -euo pipefail

: "${BIGQUERY_PROJECT:?set BIGQUERY_PROJECT to your GCP project id}"
LOCATION="${BIGQUERY_LOCATION:-US}"
DATASET="${BIGQUERY_RAW_DATASET:-ads_raw}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$HERE/data/ads"
SCHEMA_DIR="$HERE/schemas"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "no generated data at $DATA_DIR -- run: python generate_ads_events.py" >&2
  exit 1
fi

echo "project:  $BIGQUERY_PROJECT"
echo "dataset:  $DATASET (location $LOCATION)"
echo

bq --location="$LOCATION" mk --dataset --force "$BIGQUERY_PROJECT:$DATASET" >/dev/null
echo "dataset ready"

TABLES=(
  ads_advertisers
  ads_campaigns
  ads_creatives
  ads_requests
  ads_auction_bids
  ads_impressions
  ads_clicks
  ads_conversions
  ads_mmp_postbacks
)

for table in "${TABLES[@]}"; do
  files="$DATA_DIR/$table/*.csv.gz"
  schema="$SCHEMA_DIR/$table.json"

  if ! compgen -G "$files" >/dev/null; then
    echo "  SKIP $table (no files)" >&2
    continue
  fi
  if [[ ! -f "$schema" ]]; then
    echo "  FAIL $table (no schema at $schema)" >&2
    exit 1
  fi

  echo "  loading $table"
  # --replace so a reload is idempotent; these are full snapshots of a generated run,
  # and appending would silently double every row on a second run.
  bq --location="$LOCATION" load \
    --replace \
    --source_format=CSV \
    --skip_leading_rows=1 \
    --allow_quoted_newlines \
    --max_bad_records=0 \
    "$BIGQUERY_PROJECT:$DATASET.$table" \
    $files \
    "$schema"
done

echo
echo "loaded. row counts:"
for table in "${TABLES[@]}"; do
  count=$(bq --location="$LOCATION" query --use_legacy_sql=false --format=csv --quiet \
    "select count(*) from \`$BIGQUERY_PROJECT.$DATASET.$table\`" | tail -1)
  printf "  %-22s %12s\n" "$table" "$count"
done

echo
echo "next: dbt build --profiles-dir . --target bigquery"
