"""One way to query the warehouse, whichever warehouse is in play.

The monitoring scripts need to read the marts after dbt builds them, and the project
targets two warehouses. Rather than each script growing its own connection logic,
they all call query() here.

DuckDB is used when the python package is importable and the database file exists.
Otherwise the bq CLI is shelled out to with --format=json. That ordering matters: a
developer running locally gets the fast path with no cloud cost, and CI or a cloud
run gets BigQuery without changing anything.

Deliberately read-only. These scripts observe the warehouse; dbt is the only thing
that writes to it.
"""

from __future__ import annotations

import json
import os
import subprocess

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUCKDB_PATH = os.path.join(HERE, "gaming.duckdb")


class WarehouseUnavailable(RuntimeError):
    pass


def _duckdb_available() -> bool:
    if not os.path.exists(DUCKDB_PATH):
        return False
    try:
        import duckdb  # noqa: F401
        return True
    except ImportError:
        return False


def backend() -> str:
    if _duckdb_available():
        return "duckdb"
    if os.environ.get("BIGQUERY_PROJECT"):
        return "bigquery"
    raise WarehouseUnavailable(
        "no warehouse reachable: gaming.duckdb not found (or the duckdb package is "
        "not installed), and BIGQUERY_PROJECT is unset. Run `dbt build --profiles-dir .` "
        "first, or export BIGQUERY_PROJECT to read from BigQuery."
    )


def schema_prefix() -> str:
    """Model schemas differ by target, so callers ask for the prefix they need.

    On DuckDB the profile's schema is `main`, and dbt appends the custom schema, so a
    marts model lands in `main_ads_core`. On BigQuery the dataset is configured in the
    profile and dbt appends the same suffix.
    """
    if backend() == "duckdb":
        return "main_"
    dataset = os.environ.get("BIGQUERY_DATASET", "gaming_ads_platform")
    return f"{os.environ['BIGQUERY_PROJECT']}.{dataset}_"


def query(sql: str) -> list[dict]:
    """Run a read-only query and return rows as dicts."""
    if backend() == "duckdb":
        import duckdb

        con = duckdb.connect(DUCKDB_PATH, read_only=True)
        try:
            cur = con.sql(sql)
            columns = cur.columns
            return [dict(zip(columns, row)) for row in cur.fetchall()]
        finally:
            con.close()

    result = subprocess.run(
        ["bq", "query", "--use_legacy_sql=false", "--format=json", "--quiet", sql],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise WarehouseUnavailable(f"bq query failed: {result.stderr.strip()}")
    return json.loads(result.stdout or "[]")
