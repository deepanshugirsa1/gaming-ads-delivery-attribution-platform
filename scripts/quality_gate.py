"""Decide whether this build is fit to publish, and fail loudly if it is not.

dbt tests answer "is each table internally valid". This answers the question after
that one: are the pipeline's own health signals acceptable right now. They are
different questions, and only the second one catches a build where every test passes
and the data is still not usable -- a feed arriving six hours late, a feature whose
null rate tripled, a measurement partner silently dropping a third of its postbacks.

Two sources are read. dbt's own run_results.json gives test outcomes without touching
the warehouse. The monitoring marts give the operational picture. Each gate carries
its own threshold and severity: an error fails the build, a warning is recorded and
surfaced but does not block.

Writes quality_report.json and exits non-zero if any error-level gate fails, so CI
can depend on it and a scheduler can alert on it.

Usage:
    python scripts/quality_gate.py
    python scripts/quality_gate.py --self-test   # exercise the logic, no warehouse
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import warehouse  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUN_RESULTS = os.path.join(HERE, "target", "run_results.json")

# Gate definitions. Each is a query returning exactly one row with a `value` column,
# plus the comparison and the limit. Keeping them declarative means the thresholds are
# readable in one place instead of buried in branching code.
GATES = [
    {
        "name": "feeds_within_freshness_sla",
        "severity": "error",
        "description": "every ingested feed is inside its lag SLA",
        "sql": "select count(*) as value from {p}ads_measurement.mart_ads_pipeline_health "
               "where not is_within_sla",
        "operator": "<=",
        "limit": 0,
    },
    {
        "name": "feed_duplicate_rate",
        "severity": "warn",
        "description": "duplicate rate on any feed stays under 1%",
        "sql": "select coalesce(max(duplicate_rate), 0) as value "
               "from {p}ads_measurement.mart_ads_pipeline_health",
        "operator": "<=",
        "limit": 0.01,
    },
    {
        "name": "orphan_click_rate",
        "severity": "warn",
        "description": "clicks with no logged impression stay under 1%",
        "sql": "select coalesce(max(orphan_click_rate), 0) as value "
               "from {p}ads_measurement.mart_ads_pipeline_health",
        "operator": "<=",
        "limit": 0.01,
    },
    {
        "name": "conversions_beyond_lookback",
        "severity": "error",
        "description": "no conversion arrived later than the incremental lookback would catch",
        "sql": "select coalesce(max(conversions_beyond_lookback), 0) as value "
               "from {p}ads_measurement.mart_ads_pipeline_health",
        "operator": "<=",
        "limit": 0,
    },
    {
        "name": "ml_feature_null_rate_breaches",
        "severity": "error",
        "description": "no ML feature exceeds its null-rate floor on the latest day",
        "sql": "select count(*) as value from {p}ads_ml.mart_ml_feature_health_daily "
               "where is_null_rate_breach "
               "and as_of_date = (select max(as_of_date) from {p}ads_ml.mart_ml_feature_health_daily)",
        "operator": "<=",
        "limit": 0,
    },
    {
        "name": "ml_constant_features",
        "severity": "error",
        "description": "no ML feature is constant (a broken join or a forgotten column)",
        "sql": "select count(distinct feature_name) as value "
               "from {p}ads_ml.mart_ml_feature_health_daily where is_constant",
        "operator": "<=",
        "limit": 0,
    },
    {
        "name": "ml_feature_drift_breaches",
        "severity": "warn",
        "description": "features drifting against their own trailing baseline",
        "sql": "select count(*) as value from {p}ads_ml.mart_ml_feature_health_daily "
               "where is_drift_breach "
               "and as_of_date = (select max(as_of_date) from {p}ads_ml.mart_ml_feature_health_daily)",
        "operator": "<=",
        "limit": 2,
    },
    {
        "name": "ml_train_holdout_skew",
        "severity": "warn",
        "description": "features whose holdout distribution departs from training",
        "sql": "select count(*) as value from {p}ads_ml.mart_ml_training_serving_skew "
               "where is_skew_breach",
        "operator": "<=",
        "limit": 3,
    },
    {
        "name": "measurement_parity_breach_share",
        "severity": "warn",
        "description": "share of comparable campaign-days outside parity tolerance",
        "sql": "select coalesce(avg(case when is_parity_breach then 1.0 else 0.0 end), 0) as value "
               "from {p}ads_measurement.mart_measurement_parity where has_sufficient_volume",
        "operator": "<=",
        "limit": 0.25,
    },
    {
        "name": "training_set_not_empty",
        "severity": "error",
        "description": "the training set has rows with mature labels",
        "sql": "select count(*) as value from {p}ads_ml.mart_ml_training_set "
               "where is_conversion_label_mature",
        "operator": ">=",
        "limit": 1,
    },
]


def compare(value, operator: str, limit) -> bool:
    if value is None:
        return False
    value = float(value)
    limit = float(limit)
    if operator == "<=":
        return value <= limit
    if operator == ">=":
        return value >= limit
    if operator == "==":
        return value == limit
    raise ValueError(f"unsupported operator {operator}")


def read_dbt_results() -> dict:
    """Summarize dbt's own test outcomes, which need no warehouse connection."""
    if not os.path.exists(RUN_RESULTS):
        return {"available": False, "reason": "target/run_results.json not found"}
    payload = json.load(open(RUN_RESULTS))
    counts: dict[str, int] = {}
    failed_tests: list[str] = []
    for result in payload.get("results", []):
        status = result.get("status", "unknown")
        counts[status] = counts.get(status, 0) + 1
        node = result.get("unique_id", "")
        if node.startswith("test.") and status in ("fail", "error"):
            failed_tests.append(node.split(".")[-2] if "." in node else node)
    return {
        "available": True,
        "status_counts": counts,
        "failed_tests": failed_tests,
        "dbt_version": payload.get("metadata", {}).get("dbt_version"),
        "generated_at": payload.get("metadata", {}).get("generated_at"),
    }


def evaluate(gates: list[dict], values: dict) -> list[dict]:
    """Pure evaluation, separated from the querying so it can be tested directly."""
    out = []
    for gate in gates:
        value = values.get(gate["name"])
        if value is None:
            out.append({**{k: gate[k] for k in ("name", "severity", "description")},
                        "value": None, "limit": gate["limit"], "operator": gate["operator"],
                        "status": "error" if gate["severity"] == "error" else "warn",
                        "detail": "gate could not be evaluated"})
            continue
        passed = compare(value, gate["operator"], gate["limit"])
        out.append({
            "name": gate["name"],
            "severity": gate["severity"],
            "description": gate["description"],
            "value": value,
            "operator": gate["operator"],
            "limit": gate["limit"],
            "status": "pass" if passed else gate["severity"],
            "detail": f"{value} {gate['operator']} {gate['limit']}"
                      + ("" if passed else "  <-- breached"),
        })
    return out


def self_test() -> int:
    """Exercise the evaluation logic on fixed inputs, with no warehouse.

    Worth having because the thresholds are the part most likely to be edited in a
    hurry, and a gate that silently always passes is worse than no gate at all.
    """
    fixtures = {
        "feeds_within_freshness_sla": 0,
        "feed_duplicate_rate": 0.004,
        "orphan_click_rate": 0.0015,
        "conversions_beyond_lookback": 0,
        "ml_feature_null_rate_breaches": 0,
        "ml_constant_features": 0,
        "ml_feature_drift_breaches": 1,
        "ml_train_holdout_skew": 0,
        "measurement_parity_breach_share": 0.10,
        "training_set_not_empty": 12345,
    }
    healthy = evaluate(GATES, fixtures)
    assert all(g["status"] == "pass" for g in healthy), "healthy fixtures should pass"

    broken = dict(fixtures)
    broken["feeds_within_freshness_sla"] = 2
    broken["ml_constant_features"] = 1
    broken["measurement_parity_breach_share"] = 0.9
    broken["training_set_not_empty"] = 0
    results = evaluate(GATES, broken)
    errors = [g for g in results if g["status"] == "error"]
    warns = [g for g in results if g["status"] == "warn"]
    assert len(errors) == 3, f"expected 3 error gates, got {len(errors)}"
    assert len(warns) == 1, f"expected 1 warning gate, got {len(warns)}"

    missing = evaluate(GATES, {})
    assert all(g["status"] != "pass" for g in missing), "unevaluated gates must not pass"

    print("  self-test: healthy fixtures pass, broken fixtures raise 3 errors and 1 warning,")
    print("  and gates with no value never report pass. Logic verified without a warehouse.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Gate the build on pipeline health.")
    ap.add_argument("--self-test", action="store_true",
                    help="verify the gate logic against fixtures and exit")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    dbt_results = read_dbt_results()

    try:
        prefix = warehouse.schema_prefix()
        backend = warehouse.backend()
    except warehouse.WarehouseUnavailable as exc:
        print(f"  cannot evaluate gates: {exc}")
        return 1

    values: dict = {}
    errors: list[str] = []
    for gate in GATES:
        sql = gate["sql"].format(p=prefix)
        try:
            rows = warehouse.query(sql)
            values[gate["name"]] = rows[0]["value"] if rows else None
        except Exception as exc:  # noqa: BLE001 - a failed gate query is a gate failure
            errors.append(f"{gate['name']}: {exc}")

    results = evaluate(GATES, values)
    failed = [r for r in results if r["status"] == "error"]
    warned = [r for r in results if r["status"] == "warn"]

    if dbt_results.get("available") and dbt_results.get("failed_tests"):
        failed.append({
            "name": "dbt_tests",
            "severity": "error",
            "description": "all dbt tests pass",
            "value": len(dbt_results["failed_tests"]),
            "operator": "<=",
            "limit": 0,
            "status": "error",
            "detail": "failing tests: " + ", ".join(dbt_results["failed_tests"][:10]),
        })
        results.append(failed[-1])

    report = {
        "evaluated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
        "backend": backend,
        "dbt_run_results": dbt_results,
        "gates": results,
        "query_errors": errors,
        "errors": len(failed),
        "warnings": len(warned),
        "verdict": "fail" if failed or errors else "pass",
    }
    with open(os.path.join(HERE, "quality_report.json"), "w") as fh:
        json.dump(report, fh, indent=2, default=str)

    width = max(len(r["name"]) for r in results) + 2
    for r in results:
        mark = {"pass": "PASS", "warn": "WARN", "error": "FAIL"}[r["status"]]
        print(f"  [{mark}] {r['name']:<{width}} {r['detail']}")
    for e in errors:
        print(f"  [FAIL] {e}")
    print(f"\n  verdict: {report['verdict'].upper()} "
          f"({report['errors']} errors, {report['warnings']} warnings) -> quality_report.json")

    return 1 if report["verdict"] == "fail" else 0


if __name__ == "__main__":
    sys.exit(main())
