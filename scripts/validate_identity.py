"""Measure the identity graph against ground truth the models cannot see.

The generator knows which person each device belongs to. That mapping is written to
data/ads/_ground_truth_identity.csv.gz and deliberately never loaded, so the resolution
models have to earn every match from observable signals alone.

What this reports, and why each number matters:

  * Deterministic precision must be exactly 1.0. Those links come from an observed
    signed-in account, so anything less means the link is being read or joined wrongly,
    and since every probabilistic match is anchored to them the error would propagate.

  * Probabilistic precision is the number that decides whether the rule is worth
    running. A probabilistic match that is wrong does not merely fail to credit a
    conversion -- it credits it to the wrong person, corrupting a second campaign's
    numbers and the training labels downstream. That asymmetry is why the floor here is
    high and why identity_min_confidence errs toward leaving devices unresolved.

  * Coverage is reported but never optimised alone. Coverage rises trivially by
    lowering the threshold; the pair of numbers only means something together.

Requires a built warehouse. Run after `dbt build`.

Usage:
    python scripts/validate_identity.py [--min-probabilistic-precision 0.80]
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import warehouse  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRUTH = os.path.join(HERE, "data", "ads", "_ground_truth_identity.csv.gz")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-probabilistic-precision", type=float, default=0.80)
    args = ap.parse_args()

    if not os.path.exists(TRUTH):
        print(f"  ground truth not found at {TRUTH}; run generate_ads_events.py first")
        return 1
    try:
        prefix = warehouse.schema_prefix()
    except warehouse.WarehouseUnavailable as exc:
        print(f"  {exc}")
        return 1

    truth = pd.read_csv(TRUTH)
    graph = pd.DataFrame(warehouse.query(f"""
        select device_id, resolved_user_id, resolution_method, resolution_confidence,
               is_deterministic, candidate_user_count
        from {prefix}ads_identity.dim_identity_graph
    """))
    if graph.empty:
        print("  dim_identity_graph is empty; has dbt built?")
        return 1

    df = truth.merge(graph, on="device_id", how="outer", indicator=True)
    missing = int((df["_merge"] == "left_only").sum())
    extra = int((df["_merge"] == "right_only").sum())
    df = df[df["_merge"] == "both"].copy()

    df["resolved"] = df["resolved_user_id"].notna()
    df["correct"] = df["resolved"] & (df["resolved_user_id"] == df["true_user_id"])

    total = len(df)
    resolved = int(df["resolved"].sum())
    correct = int(df["correct"].sum())

    by_method = (
        df.groupby("resolution_method")
        .agg(devices=("device_id", "count"),
             resolved=("resolved", "sum"),
             correct=("correct", "sum"))
        .reset_index()
    )
    by_method["precision"] = by_method.apply(
        lambda r: (r["correct"] / r["resolved"]) if r["resolved"] else None, axis=1
    )

    det = by_method[by_method["resolution_method"] == "deterministic"]
    prob = by_method[by_method["resolution_method"] == "probabilistic"]
    det_precision = float(det["precision"].iloc[0]) if len(det) and det["resolved"].iloc[0] else None
    prob_precision = float(prob["precision"].iloc[0]) if len(prob) and prob["resolved"].iloc[0] else None

    report = {
        "devices_compared": total,
        "devices_missing_from_graph": missing,
        "devices_not_in_ground_truth": extra,
        "coverage": resolved / total if total else None,
        "overall_precision": correct / resolved if resolved else None,
        "deterministic_precision": det_precision,
        "probabilistic_precision": prob_precision,
        "by_method": by_method.to_dict(orient="records"),
    }
    with open(os.path.join(HERE, "identity_validation.json"), "w") as fh:
        json.dump(report, fh, indent=2, default=str)

    print(f"  devices compared            {total:,}")
    print(f"  resolved                    {resolved:,}  ({resolved / total:.1%} coverage)")
    print(f"  correctly resolved          {correct:,}  ({correct / resolved:.2%} precision)"
          if resolved else "  resolved 0")
    print()
    print(f"  {'method':<18}{'devices':>9}{'resolved':>10}{'correct':>9}{'precision':>11}")
    for r in by_method.sort_values("devices", ascending=False).itertuples():
        p = f"{r.precision:.2%}" if r.precision is not None else "-"
        print(f"  {r.resolution_method:<18}{r.devices:>9,}{int(r.resolved):>10,}"
              f"{int(r.correct):>9,}{p:>11}")

    failures = []
    if missing or extra:
        failures.append(f"{missing} devices missing from the graph, {extra} not in ground truth")
    if det_precision is not None and det_precision < 1.0:
        failures.append(
            f"deterministic precision is {det_precision:.2%}, must be exactly 100% — "
            "these links come from an observed account and anchor every probabilistic match"
        )
    if prob_precision is not None and prob_precision < args.min_probabilistic_precision:
        failures.append(
            f"probabilistic precision {prob_precision:.2%} is below the "
            f"{args.min_probabilistic_precision:.0%} floor — raise identity_min_confidence "
            "or add a signal; a wrong match credits one person's conversion to another"
        )

    print()
    if failures:
        print("  FAIL")
        for f in failures:
            print(f"    - {f}")
        return 1
    print("  PASS: deterministic links exact, probabilistic matching above its floor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
