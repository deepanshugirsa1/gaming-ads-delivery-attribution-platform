"""Validate the generated ad feeds before the warehouse ever reads them.

Two jobs.

First, referential integrity and auction mechanics: every impression traces to a
real request, every bid to a real campaign and creative, every ad request to a user
who exists and a server that user joined, and exactly one bid wins each auction.
If any of that is wrong, every downstream number is wrong, and it is far cheaper to
catch it here than to debug a mart.

Second, confirm that the anomalies the pipeline claims to handle are actually
present at roughly the planted rate. A test that passes because the bad data was
never generated is worse than no test -- it reports health that was never exercised.
So this asserts duplicates, orphan clicks, late arrivals, out-of-window conversions,
organic conversions, and every third-party measurement defect genuinely exist.

Writes validation_report.json and exits non-zero on failure, so it can gate CI.

Usage:
    python scripts/validate_generated_data.py
"""

from __future__ import annotations

import json
import os
import sys

import pandas as pd

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADS = os.path.join(HERE, "data", "ads")
SEEDS = os.path.join(HERE, "seeds")

CLICK_WINDOW_DAYS = 7
VIEW_WINDOW_DAYS = 1


def load(table: str) -> pd.DataFrame:
    path = os.path.join(ADS, table, "part-00000.csv.gz")
    if not os.path.exists(path):
        raise SystemExit(f"missing {path}; run `python generate_ads_events.py` first")
    return pd.read_csv(path)


class Checks:
    def __init__(self) -> None:
        self.results: list[dict] = []

    def check(self, name: str, passed: bool, detail: str, severity: str = "error") -> None:
        self.results.append(
            {"check": name, "status": "pass" if passed else severity, "detail": detail}
        )

    def expect_rate(self, name: str, observed: float, planted: float, n: int,
                    sigmas: float = 4.0) -> None:
        """Compare an observed rate to the planted one inside a binomial band.

        A planted 2% rate observed over 275 rows can easily present as 3.3% through
        sampling alone, so a fixed percentage band fails for no reason at low volume
        and is far too loose at high volume. Using +/- 4 standard errors instead means
        the band tightens as the generated volume grows: at a few hundred postbacks it
        is forgiving, at a few hundred thousand impressions it is strict. A check that
        cries wolf at small scale is a check people learn to ignore.
        """
        se = (planted * (1 - planted) / max(n, 1)) ** 0.5
        margin = max(sigmas * se, 0.002)
        lo, hi = max(planted - margin, 0.0), planted + margin
        self.check(
            name,
            lo <= observed <= hi,
            f"observed {observed:.5f}, planted {planted:.5f}, "
            f"accepted [{lo:.5f}, {hi:.5f}] (n={n:,}, +/-{sigmas:g} SE)",
        )

    @property
    def failed(self) -> list[dict]:
        return [r for r in self.results if r["status"] == "error"]


def main() -> int:
    manifest_path = os.path.join(ADS, "_manifest.json")
    manifest = json.load(open(manifest_path)) if os.path.exists(manifest_path) else {}
    planted = {**manifest.get("planted_anomaly_rates", {}), **manifest.get("identity_rates", {})}

    users = pd.read_csv(os.path.join(SEEDS, "raw_users.csv"))
    servers = pd.read_csv(os.path.join(SEEDS, "raw_servers.csv"))
    joins = pd.read_csv(os.path.join(SEEDS, "raw_server_joins.csv"))

    campaigns = load("ads_campaigns")
    creatives = load("ads_creatives")
    requests = load("ads_requests")
    bids = load("ads_auction_bids")
    impressions = load("ads_impressions")
    clicks = load("ads_clicks")
    conversions = load("ads_conversions")
    postbacks = load("ads_mmp_postbacks")
    progress = load("ads_quest_progress")
    devices = load("ads_device_identities")
    identity_truth = pd.read_csv(os.path.join(ADS, "_ground_truth_identity.csv.gz"))
    truth = pd.read_csv(os.path.join(ADS, "_ground_truth_attribution.csv.gz"))

    c = Checks()

    # ---------------- referential integrity ----------------
    c.check(
        "requests.user_id subset of users",
        requests["user_id"].isin(set(users["user_id"])).all(),
        f"{(~requests['user_id'].isin(set(users['user_id']))).sum()} orphan user_ids",
    )
    membership = set(zip(joins["user_id"], joins["server_id"]))
    sample = requests.sample(min(50_000, len(requests)), random_state=0)
    bad_mem = sum(1 for u, s in zip(sample["user_id"], sample["server_id"]) if (u, s) not in membership)
    c.check(
        "requests serve on a server the user joined",
        bad_mem == 0,
        f"{bad_mem} of {len(sample)} sampled requests on a non-member server",
    )
    c.check(
        "bids.campaign_id subset of campaigns",
        bids["campaign_id"].isin(set(campaigns["campaign_id"])).all(),
        "all bid campaigns exist",
    )
    c.check(
        "bids.creative_id subset of creatives",
        bids["creative_id"].isin(set(creatives["creative_id"])).all(),
        "all bid creatives exist",
    )
    c.check(
        "impressions.request_id subset of requests",
        impressions["request_id"].isin(set(requests["request_id"])).all(),
        "every impression traces to an auction",
    )

    # creative must belong to the campaign that bid it
    crt_owner = creatives.set_index("creative_id")["campaign_id"]
    mism = (bids["creative_id"].map(crt_owner) != bids["campaign_id"]).sum()
    c.check("bid creative belongs to bid campaign", mism == 0, f"{mism} mismatched bids")

    # ---------------- auction mechanics ----------------
    winners = bids.groupby("request_id")["is_winner"].sum()
    c.check(
        "exactly one winner per contested auction",
        (winners == 1).all(),
        f"{(winners != 1).sum()} requests with a winner count other than 1",
    )
    requests_with_bids = bids["request_id"].nunique()
    c.check(
        "unfilled requests exist (no eligible campaign)",
        requests_with_bids < len(requests),
        f"{len(requests) - requests_with_bids:,} of {len(requests):,} requests had no eligible campaign",
    )

    # targeting actually enforced
    cat = servers.set_index("server_id")["category"]
    req_ctx = requests.set_index("request_id")[["country", "device_platform", "server_id"]]
    bsample = bids.sample(min(50_000, len(bids)), random_state=0).join(req_ctx, on="request_id")
    bsample["category"] = bsample["server_id"].map(cat)
    camp_t = campaigns.set_index("campaign_id")
    violations = 0
    for row in bsample.itertuples():
        t = camp_t.loc[row.campaign_id]
        for clause, value in (
            (t.target_countries, row.country),
            (t.target_platforms, row.device_platform),
            (t.target_server_categories, row.category),
        ):
            if clause != "ALL" and value not in clause.split("|"):
                violations += 1
                break
    c.check(
        "every bid satisfies its campaign targeting",
        violations == 0,
        f"{violations} of {len(bsample)} sampled bids violate targeting",
    )

    # ---------------- planted defects ----------------
    dup_rate = 1 - impressions["impression_id"].nunique() / len(impressions)
    c.expect_rate("duplicate impression retransmissions present", dup_rate,
                  planted.get("duplicate_impressions", 0.004), n=len(impressions))

    orphan = (~clicks["impression_id"].isin(set(impressions["impression_id"]))).sum()
    c.check("orphan clicks present", orphan > 0,
            f"{orphan} clicks reference an impression that was never logged")

    conversions["conversion_ts"] = pd.to_datetime(conversions["conversion_ts"])
    conversions["ingest_ts"] = pd.to_datetime(conversions["ingest_ts"])
    late = (conversions["ingest_ts"] - conversions["conversion_ts"]).dt.total_seconds() / 3600
    c.check("conversions arrive late", (late > 1).any(),
            f"median lag {late.median():.2f}h, p95 {late.quantile(0.95):.2f}h, max {late.max():.2f}h")
    c.check("late arrival exceeds one day for some conversions", (late > 24).any(),
            f"{(late > 24).sum()} conversions arrived more than 24h after the event")

    organic_share = (truth["truth_touchpoint"] == "organic").mean()
    c.expect_rate("organic (unattributable) conversions present", organic_share,
                  planted.get("organic_conversion_share", 0.20), n=len(truth))

    c.check("view-through conversions present",
            (truth["truth_touchpoint"] == "view").sum() > 0,
            f"{(truth['truth_touchpoint'] == 'view').sum()} view-through conversions")

    # conversions that fall outside the attribution window must exist, or the
    # window logic is never actually exercised
    imp_ts = impressions.drop_duplicates("impression_id").set_index("impression_id")["impression_ts"]
    t2 = truth[truth["truth_touchpoint"].isin(["click", "view"])].copy()
    t2["imp_ts"] = pd.to_datetime(t2["truth_impression_id"].map(imp_ts))
    t2["conversion_ts"] = pd.to_datetime(t2["conversion_ts"])
    t2["lag_days"] = (t2["conversion_ts"] - t2["imp_ts"]).dt.total_seconds() / 86400
    out_click = ((t2["truth_touchpoint"] == "click") & (t2["lag_days"] > CLICK_WINDOW_DAYS)).sum()
    out_view = ((t2["truth_touchpoint"] == "view") & (t2["lag_days"] > VIEW_WINDOW_DAYS)).sum()
    c.check("conversions outside the click window exist", out_click > 0,
            f"{out_click} conversions land beyond the {CLICK_WINDOW_DAYS}d click window")
    c.check("conversions outside the view window exist", out_view > 0,
            f"{out_view} conversions land beyond the {VIEW_WINDOW_DAYS}d view window")

    # ---------------- third-party measurement defects ----------------
    pb_dup = 1 - postbacks["postback_id"].nunique() / len(postbacks)
    c.expect_rate("duplicate postback retransmissions present", pb_dup,
                  planted.get("mmp_duplicate_postbacks", 0.02), n=len(postbacks))

    # Identity loss on a postback is compound, not a single rate. The partner can only
    # pass an identifier we had in the first place, so a postback loses its user if
    # first-party identity was already missing OR the partner drops its own. Comparing
    # against the partner's rate alone would flag healthy data every run.
    null_user = postbacks["claimed_user_id"].isna().mean()
    p_first_party = planted.get("unidentified_conversions", 0.12)
    p_partner = planted.get("mmp_null_user", 0.03)
    expected_null = 1 - (1 - p_first_party) * (1 - p_partner)
    c.expect_rate("postbacks with no usable user identifier (compound loss)", null_user,
                  expected_null, n=len(postbacks))

    mmp_only = (~postbacks["claimed_user_id"].isna()) & (
        ~postbacks["postback_id"].str.startswith("pb_only_") == False
    )
    c.check("MMP-only conversions present (no first-party record)",
            postbacks["postback_id"].str.startswith("pb_only_").any(),
            f"{postbacks['postback_id'].str.startswith('pb_only_').sum()} MMP-only postbacks")

    # campaign disagreement, measured against ground truth
    pb_real = postbacks[~postbacks["postback_id"].str.startswith("pb_only_")].drop_duplicates("postback_id")
    tr = truth.dropna(subset=["truth_campaign_id"]).set_index("conversion_id")["truth_campaign_id"]
    joined = pb_real.copy()
    # postbacks carry no conversion_id by design; match on user + event + timestamp
    truth_keyed = truth.copy()
    truth_keyed["event_ts"] = pd.to_datetime(truth_keyed["conversion_ts"]).dt.strftime("%Y-%m-%d %H:%M:%S")
    key_cols = ["user_id", "event_ts"]
    joined["user_id"] = joined["claimed_user_id"]
    merged = joined.merge(
        truth_keyed[["user_id", "event_ts", "truth_campaign_id", "truth_touchpoint"]],
        on=key_cols, how="inner",
    )
    matched = merged.dropna(subset=["truth_campaign_id"])
    if len(matched):
        disagree = (matched["claimed_campaign_id"] != matched["truth_campaign_id"]).mean()
        c.expect_rate("third-party credits a different campaign than first-party",
                      disagree, planted.get("mmp_campaign_disagreement", 0.06), n=len(matched))
    else:
        c.check("third-party disagreement measurable", False,
                "could not join postbacks to ground truth", severity="warn")

    received_lag = (
        pd.to_datetime(postbacks["received_ts"]) - pd.to_datetime(postbacks["event_ts"])
    ).dt.total_seconds() / 3600
    c.check("postbacks arrive after the event they describe",
            (received_lag >= 0).all(),
            f"median postback delay {received_lag.median():.2f}h, max {received_lag.max():.2f}h")

    # ---------------- rewarded quest mechanics ----------------
    imp_ids = set(impressions["impression_id"])
    c.check(
        "quest progress traces to a real impression",
        progress["impression_id"].isin(imp_ids).all(),
        f"{(~progress['impression_id'].isin(imp_ids)).sum()} orphan progress rows",
    )

    camp_idx = campaigns.set_index("campaign_id")
    crt_dur = creatives.set_index("creative_id")["duration_sec"]
    reward = progress[progress["milestone"] == "reward_granted"].copy()
    c.check("rewards are granted", len(reward) > 0, f"{len(reward):,} reward events")

    reward["threshold_sec"] = reward["campaign_id"].map(camp_idx["completion_threshold_seconds"])
    reward["required_min"] = reward["campaign_id"].map(camp_idx["required_playtime_minutes"])
    reward["duration_sec"] = reward["creative_id"].map(crt_dur)

    bad_video = reward[
        (reward["quest_format"] == "video_quest")
        & (reward["seconds_viewed"] < reward["threshold_sec"])
    ]
    bad_reserve = reward[
        (reward["quest_format"] == "video_quest_reserve")
        & (reward["seconds_viewed"] < reward["duration_sec"])
    ]
    bad_play = reward[
        reward["quest_format"].isin(["play_quest", "arena_quest"])
        & (reward["playtime_minutes"] < reward["required_min"])
    ]
    c.check(
        "no reward granted below its format's threshold",
        len(bad_video) == 0 and len(bad_reserve) == 0 and len(bad_play) == 0,
        f"{len(bad_video)} video, {len(bad_reserve)} reserve, {len(bad_play)} playtime violations",
    )
    c.check(
        "reserve quests only reward on full completion",
        len(reward[reward["quest_format"] == "video_quest_reserve"]) == 0
        or (reward[reward["quest_format"] == "video_quest_reserve"]["progress_pct"] >= 0.99).all(),
        "every reserve reward is at 100% progress",
    )

    # funnel monotonicity: reaching a later quartile implies reaching the earlier ones
    q = progress[progress["milestone"].str.startswith("quartile_")]
    counts = q.groupby("milestone")["impression_id"].nunique()
    mono = all(
        counts.get(a, 0) >= counts.get(b, 0)
        for a, b in [("quartile_25", "quartile_50"), ("quartile_50", "quartile_75")]
    )
    c.check("quartile funnel is monotonic", mono,
            ", ".join(f"{k}={v:,}" for k, v in sorted(counts.items())))

    completed = progress[progress["milestone"] == "view_complete"]["impression_id"].nunique()
    video_imps = impressions[
        impressions["creative_id"].map(crt_dur).fillna(0) > 0
    ]["impression_id"].nunique()
    c.check("video completion rate is plausible",
            0.02 <= (completed / video_imps if video_imps else 0) <= 0.85,
            f"{completed:,} completed of {video_imps:,} video impressions")

    # ---------------- auction versus reserved inventory ----------------
    reserved_campaigns = set(camp_idx[camp_idx["buying_model"] == "reservation"].index)
    c.check("reserved inventory exists", len(reserved_campaigns) > 0,
            f"{len(reserved_campaigns)} reservation campaigns of {len(campaigns)}")

    bids_r = bids.copy()
    bids_r["is_reservation"] = bids_r["campaign_id"].isin(reserved_campaigns)
    contested = bids_r.groupby("request_id")["is_reservation"].max()
    winners_only = bids_r[bids_r["is_winner"] == 1].set_index("request_id")["is_reservation"]
    both = contested[contested == True].index.intersection(winners_only.index)
    lost_reservations = int((~winners_only.loc[both]).sum()) if len(both) else 0
    c.check(
        "a reservation never loses an auction it entered",
        lost_reservations == 0,
        f"{lost_reservations} auctions where reserved inventory was outbid",
    )

    tiers = advertisers_tiers = load("ads_advertisers")["advertiser_tier"].value_counts().to_dict()
    c.check("all three advertiser tiers present", len(tiers) == 3, str(tiers))

    # ---------------- per-partner contract behaviour ----------------
    c.check(
        "both measurement contracts present",
        postbacks["feed_contract"].nunique() == 2,
        str(postbacks["feed_contract"].value_counts().to_dict()),
    )

    # ---------------- identity signals ----------------
    c.check(
        "device feed carries no user column",
        "user_id" not in devices.columns and "true_user_id" not in devices.columns,
        "ownership is a question for the graph, not an input to it",
    )
    dev_ids = set(devices["device_id"])
    c.check("requests reference a real device",
            requests["device_id"].isin(dev_ids).all(),
            f"{(~requests['device_id'].isin(dev_ids)).sum()} unknown device ids on requests")
    c.check("conversions reference a real device",
            conversions["conversion_device_id"].isin(dev_ids).all(),
            f"{(~conversions['conversion_device_id'].isin(dev_ids)).sum()} unknown device ids")
    c.check("ground truth covers every device",
            set(identity_truth["device_id"]) == dev_ids,
            f"{len(identity_truth):,} truth rows against {len(dev_ids):,} devices")

    signed_in = devices["signed_in_account_id"].notna().mean()
    c.expect_rate("devices with an observable account link", signed_in,
                  planted.get("signed_in_devices", 0.70), n=len(devices))

    unident = conversions["user_id"].isna().mean()
    c.expect_rate("conversions arriving with no user identifier", unident,
                  planted.get("unidentified_conversions", 0.12), n=len(conversions))

    # a conversion on a device other than the one that saw the ad
    imp_dev = impressions.drop_duplicates("impression_id").set_index("impression_id")["device_id"]
    t3 = truth[truth["truth_impression_id"].notna()].copy()
    t3["serving_device"] = t3["truth_impression_id"].map(imp_dev)
    conv_dev = conversions.set_index("conversion_id")["conversion_device_id"]
    t3["conv_device"] = t3["conversion_id"].map(conv_dev)
    t3 = t3.dropna(subset=["serving_device", "conv_device"])
    # Measured over people who actually have more than one device — the only
    # population for whom a cross-device conversion is possible at all.
    devices_per_user = identity_truth.groupby("true_user_id").size()
    t3["device_count"] = t3["user_id"].map(devices_per_user)
    t3_multi = t3[t3["device_count"] > 1]
    cross = (t3_multi["serving_device"] != t3_multi["conv_device"]).mean() if len(t3_multi) else 0
    c.expect_rate("multi-device people converting on a different device", cross,
                  planted.get("cross_device_conversions", 0.22), n=max(len(t3_multi), 1))

    recoverable = postbacks[postbacks["claimed_user_id"].isna()]
    c.check(
        "postbacks with no user still carry a device",
        len(recoverable) == 0 or recoverable["claimed_device_id"].notna().all(),
        f"{len(recoverable)} postbacks lack a user; all retain a device identifier",
    )

    multi_device_users = identity_truth.groupby("true_user_id").size()
    c.check("people have more than one device",
            (multi_device_users > 1).any(),
            f"median {multi_device_users.median():.0f} devices per person, "
            f"max {multi_device_users.max()}")

    # ---------------- plausibility of headline rates ----------------
    imp_unique = impressions["impression_id"].nunique()
    ctr = clicks["impression_id"].isin(set(impressions["impression_id"])).sum() / imp_unique
    c.check("click-through rate is plausible for in-app placements",
            0.002 <= ctr <= 0.05, f"CTR {ctr:.4%} on {imp_unique:,} deduplicated impressions")

    fill = imp_unique / len(requests)
    c.check("fill rate is plausible", 0.5 <= fill <= 0.98, f"fill rate {fill:.2%}")

    report = {
        "generated_from_manifest": manifest.get("generated_at_utc"),
        "scale": manifest.get("scale"),
        "row_counts": manifest.get("row_counts"),
        "checks_run": len(c.results),
        "checks_failed": len(c.failed),
        "results": c.results,
    }
    out = os.path.join(HERE, "validation_report.json")
    with open(out, "w") as fh:
        json.dump(report, fh, indent=2)

    width = max(len(r["check"]) for r in c.results) + 2
    for r in c.results:
        mark = {"pass": "PASS", "warn": "WARN", "error": "FAIL"}[r["status"]]
        print(f"  [{mark}] {r['check']:<{width}} {r['detail']}")
    print(f"\n  {len(c.results)} checks, {len(c.failed)} failed -> validation_report.json")

    return 1 if c.failed else 0


if __name__ == "__main__":
    sys.exit(main())
