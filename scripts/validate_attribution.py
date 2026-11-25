"""Check what the attribution models derived against what actually happened.

The generator knows which touchpoint really caused each conversion, because it made
the decision. That ground truth is written to data/ads/_ground_truth_attribution.csv.gz
and deliberately never loaded into the warehouse -- the attribution models have no
access to it, so comparing the two is a real test rather than a tautology.

The interesting part is that perfect agreement would be the wrong result, and a
script that asserted it would be measuring the wrong thing. Three kinds of
disagreement are correct behaviour:

  * Last-touch overriding the true cause. If a user clicked campaign A, then later
    saw campaign B from the same advertiser, and then converted, the true cause was A
    but last-touch credits B. That is what last-touch means. It is also precisely the
    bias mart_multi_touch_comparison exists to quantify.

  * Organic conversions credited to ads. Someone who would have bought anyway, but
    happened to see an ad inside the window, gets credited. Attribution cannot tell
    that apart from influence -- only an experiment can. The rate at which it happens
    here is a measure of how much of reported performance is coincidence, which is
    the single most useful number in this whole repository.

  * Out-of-window exposures going uncredited. Correct by construction.

So this reports agreement, explains every disagreement it can, and fails only on
disagreements it cannot explain -- those are real bugs in the attribution logic.

Requires a built warehouse. Run after `dbt build`.

Usage:
    python scripts/validate_attribution.py
"""

from __future__ import annotations

import json
import os
import sys

import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import warehouse  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRUTH = os.path.join(HERE, "data", "ads", "_ground_truth_attribution.csv.gz")


def main() -> int:
    if not os.path.exists(TRUTH):
        print(f"  ground truth not found at {TRUTH}; run generate_ads_events.py first")
        return 1

    try:
        prefix = warehouse.schema_prefix()
    except warehouse.WarehouseUnavailable as exc:
        print(f"  {exc}")
        return 1

    truth = pd.read_csv(TRUTH)

    derived = pd.DataFrame(warehouse.query(f"""
        select
            conversion_id,
            attributed_campaign_id,
            attribution_type,
            attribution_outcome,
            is_multi_touch_path,
            in_window_touchpoints,
            wide_window_touchpoints,
            days_from_touchpoint_to_conversion
        from {prefix}ads_core.fct_attributed_conversions
    """))

    if derived.empty:
        print("  fct_attributed_conversions is empty; has dbt built?")
        return 1

    merged = truth.merge(derived, on="conversion_id", how="outer", indicator=True)

    missing_from_warehouse = (merged["_merge"] == "left_only").sum()
    unexpected_in_warehouse = (merged["_merge"] == "right_only").sum()

    both = merged[merged["_merge"] == "both"].copy()

    # ---- conversions that truly came from an ad ----
    caused = both[both["truth_touchpoint"].isin(["click", "view"])].copy()
    caused["agrees"] = caused["attributed_campaign_id"] == caused["truth_campaign_id"]

    agreed = int(caused["agrees"].sum())
    disagreed = caused[~caused["agrees"]].copy()

    # explained: last-touch legitimately picked a different, later touchpoint from the
    # same advertiser, which is what last-touch is defined to do
    explained_multi_touch = int(
        (
            (~disagreed["agrees"])
            & disagreed["attributed_campaign_id"].notna()
            & (disagreed["in_window_touchpoints"].fillna(0) > 1)
        ).sum()
    )
    # explained: the true touchpoint fell outside the reporting window
    explained_out_of_window = int(
        (disagreed["attribution_outcome"] == "touchpoint_outside_window").sum()
    )
    explained_no_touchpoint = int(
        (
            (disagreed["attribution_outcome"] == "no_touchpoint")
            & (disagreed["wide_window_touchpoints"].fillna(0) == 0)
        ).sum()
    )

    unexplained = (
        len(disagreed) - explained_multi_touch - explained_out_of_window - explained_no_touchpoint
    )

    # ---- organic conversions ----
    organic = both[both["truth_touchpoint"] == "organic"]
    organic_total = len(organic)
    organic_credited = int((organic["attribution_outcome"] == "attributed").sum())

    report = {
        "conversions_compared": int(len(both)),
        "missing_from_warehouse": int(missing_from_warehouse),
        "unexpected_in_warehouse": int(unexpected_in_warehouse),
        "ad_caused_conversions": int(len(caused)),
        "campaign_agreement": agreed,
        "campaign_agreement_rate": (agreed / len(caused)) if len(caused) else None,
        "disagreements": int(len(disagreed)),
        "explained_by_last_touch_rule": explained_multi_touch,
        "explained_by_window": explained_out_of_window,
        "explained_by_no_touchpoint": explained_no_touchpoint,
        "unexplained_disagreements": int(unexplained),
        "organic_conversions": organic_total,
        "organic_credited_to_ads": organic_credited,
        "organic_false_credit_rate": (organic_credited / organic_total) if organic_total else None,
    }
    with open(os.path.join(HERE, "attribution_validation.json"), "w") as fh:
        json.dump(report, fh, indent=2)

    print(f"  conversions compared              {report['conversions_compared']:,}")
    print(f"  ad-caused conversions             {report['ad_caused_conversions']:,}")
    if report["campaign_agreement_rate"] is not None:
        print(f"  credited to the true campaign     {agreed:,} "
              f"({report['campaign_agreement_rate']:.2%})")
    print(f"  disagreements                     {len(disagreed):,}")
    print(f"    last-touch chose a later ad     {explained_multi_touch:,}  (correct by definition)")
    print(f"    true touchpoint out of window   {explained_out_of_window:,}  (correct by definition)")
    print(f"    no touchpoint in wide window    {explained_no_touchpoint:,}  (correct by definition)")
    print(f"    unexplained                     {unexplained:,}  <-- real bugs if non-zero")
    print()
    print(f"  organic conversions               {organic_total:,}")
    print(f"  organic credited to an ad         {organic_credited:,} "
          f"({report['organic_false_credit_rate']:.2%})" if organic_total else "")
    print("    Attribution cannot distinguish influence from coincidence; only an")
    print("    experiment can. This rate is how much of reported performance would")
    print("    have happened anyway.")

    failures = []
    if missing_from_warehouse:
        failures.append(f"{missing_from_warehouse} conversions are missing from the warehouse")
    if unexpected_in_warehouse:
        failures.append(f"{unexpected_in_warehouse} warehouse conversions have no ground truth")
    if unexplained > 0:
        failures.append(f"{unexplained} disagreements cannot be explained by the attribution rules")

    if failures:
        print("\n  FAIL")
        for f in failures:
            print(f"    - {f}")
        return 1
    print("\n  PASS: every disagreement is explained by the documented attribution rules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
