"""Synthetic advertising event generator for the gaming-community platform.

This generates the ad side of the platform: auction requests, bids, impressions,
clicks, first-party conversions, and third-party measurement postbacks shaped like
the ones a Mobile Measurement Partner sends.

Three things make this more than a random-data script.

1. It reuses the real user and server universe from ``seeds/``. Every ad request
   belongs to a user who exists in ``raw_users`` and a server that user actually
   joined, so the ad models join cleanly to the engagement models and referential
   integrity is a property of the data rather than a hope.

2. Click-through rate is generated from a logistic model over features the
   warehouse can independently compute -- creative format, placement, platform,
   country, how engaged the user already was, campaign quality, and how many times
   this user has already seen this campaign. That means the ML feature tables are
   learnable rather than noise, and a model trained on them should recover roughly
   the effects planted here.

3. Every failure mode the pipeline claims to handle is planted on purpose, at a
   known rate: duplicate impression retransmissions, clicks whose impression was
   never logged, conversions that arrive days after they happened, conversions that
   fall outside the attribution window, conversions with no ad touchpoint at all,
   and third-party postbacks that disagree with first-party attribution, go missing,
   arrive twice, or lose the user identifier entirely.

Ground truth for attribution is written to a separate file that is deliberately
NOT loaded into the warehouse (``_ground_truth_attribution.csv.gz``). It exists so
scripts/validate_attribution.py can check what the dbt attribution models derived
against what actually happened. Loading it would be leakage.

Output is gzipped CSV, one folder per table, plus a BigQuery JSON schema per table
so the local and cloud runs agree on types. The data folder is gitignored -- a run
at default scale produces more rows than belong in version control.

Usage:
    python generate_ads_events.py                      # default scale
    python generate_ads_events.py --scale 10 --seed 7   # ~10x the events
    python generate_ads_events.py --scale 1 --campaigns 20   # fast CI run
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
from datetime import datetime, timezone

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
SEEDS_DIR = os.path.join(HERE, "seeds")
OUT_DIR = os.path.join(HERE, "data", "ads")
SCHEMA_DIR = os.path.join(HERE, "schemas")

# --- taxonomies -------------------------------------------------------------

VERTICALS = [
    "game_studio",
    "mobile_game",
    "hardware",
    "energy_drink",
    "streaming",
    "apparel",
    "fintech",
]
OBJECTIVES = ["awareness", "traffic", "installs", "conversions"]
BID_STRATEGIES = ["cpm", "cpc"]

# Rewarded quest formats, modeled on the ad products this platform publicly runs.
# The distinction that matters for the data model is what earns the reward:
#   video_quest          -- mobile-first rewarded video; reward at a seconds threshold
#   video_quest_reserve  -- premium reservation buy; reward only at full completion
#   play_quest           -- play a sponsored game for a required number of minutes
#   arena_quest          -- playtime-based, rewarded against time spent in a session
# A format whose reward triggers partway through a view and one that requires 100%
# completion produce completely different funnels, so format is a first-class
# dimension rather than a label on a creative.
QUEST_FORMATS = ["video_quest", "video_quest_reserve", "play_quest", "arena_quest"]
VIDEO_FORMATS = {"video_quest", "video_quest_reserve"}
PLAY_FORMATS = {"play_quest", "arena_quest"}

PLACEMENTS = ["quest_hub", "server_feed", "voice_lobby", "game_overlay", "mobile_feed"]

# Advertiser tiers reflect how the inventory is bought. Reservation buys are sold
# directly and do not compete in the auction; self-serve and managed advertisers do.
ADVERTISER_TIERS = ["self_serve", "managed", "reserve"]

# Third-party measurement feeds. Two distinct contract shapes rather than three
# interchangeable ones: a mobile install-attribution postback and a gaming
# engagement-measurement postback behave differently and disagree differently.
# These are synthetic feeds modeled on published contract shapes -- not integrations.
MMP_NAMES = ["appsflyer_style", "gamesight_style"]
MMP_CONTRACTS = {
    "appsflyer_style": "mobile_install_attribution",
    "gamesight_style": "gaming_engagement_measurement",
}

# Effects on the log-odds of a click. Signs and rough magnitudes are the thing a
# model trained on the feature tables should be able to recover.
FORMAT_EFFECT = {
    "video_quest": 0.30,
    "video_quest_reserve": 0.10,
    "play_quest": 0.45,
    "arena_quest": 0.40,
}
PLACEMENT_EFFECT = {
    "quest_hub": 0.55,
    "server_feed": 0.15,
    "voice_lobby": -0.35,
    "game_overlay": 0.20,
    "mobile_feed": 0.25,
}
PLATFORM_EFFECT = {"mobile": 0.20, "desktop": 0.0, "web": -0.20}

# Post-click conversion probability by campaign objective.
OBJECTIVE_CONV_RATE = {"awareness": 0.015, "traffic": 0.050, "installs": 0.130, "conversions": 0.180}
OBJECTIVE_EVENT = {
    "awareness": "signup",
    "traffic": "add_to_cart",
    "installs": "install",
    "conversions": "purchase",
}

# --- planted anomaly rates (quoted in the README and asserted by the tests) --

DUP_IMPRESSION_RATE = 0.004      # same impression_id re-delivered by the collector
ORPHAN_CLICK_RATE = 0.0015       # click whose impression_id was never logged
RENDER_FAILURE_RATE = 0.07       # auction won but creative never rendered
VIEW_THROUGH_RATE = 0.0008       # converts after seeing, without clicking
ORGANIC_CONV_SHARE = 0.20        # conversions with no ad touchpoint at all
MMP_COVERAGE = 0.88              # share of eligible conversions the MMP reports
MMP_CAMPAIGN_DISAGREE = 0.06     # MMP credits a different campaign than we do
MMP_NULL_USER_RATE = 0.03        # postback arrives with no usable user identifier
MMP_DUP_RATE = 0.02              # postback retransmitted with the same postback_id
MMP_ONLY_RATE = 0.04             # MMP reports a conversion we have no record of

# Identity. A person reaches the platform from more than one device, and the link
# between device and account is not always observable: a signed-out client, a cleared
# advertising identifier, a conversion recorded on a different device from the ad.
# These are the rates the identity graph has to recover from.
DEVICES_PER_USER = (1, 4)
SIGNED_IN_DEVICE_RATE = 0.70      # devices with an observable account link
SHARED_IP_RATE = 0.85             # a user's devices usually share a network prefix
MOBILE_AD_ID_RATE = 0.80          # mobile devices carrying an advertising identifier
CROSS_DEVICE_CONVERSION_RATE = 0.22   # of multi-device people, share converting elsewhere
UNIDENTIFIED_CONVERSION_RATE = 0.12   # conversion arrives with no user identifier

# Reward thresholds, from the public description of the formats.
VIDEO_REWARD_SECONDS = 15        # video_quest grants the reward at ~15 seconds viewed
PLAY_REWARD_MINUTES = (10, 30)   # play and arena quests require this many minutes

CHUNK_REQUESTS = 250_000


# BigQuery schemas. Single source of truth for types: the loader script turns these
# into --schema arguments, so the cloud tables and the local CSV never drift.
SCHEMAS: dict[str, list[tuple[str, str]]] = {
    "ads_advertisers": [
        ("advertiser_id", "STRING"),
        ("advertiser_name", "STRING"),
        ("vertical", "STRING"),
        ("advertiser_tier", "STRING"),
        ("created_ts", "TIMESTAMP"),
    ],
    "ads_campaigns": [
        ("campaign_id", "STRING"),
        ("advertiser_id", "STRING"),
        ("campaign_name", "STRING"),
        ("objective", "STRING"),
        ("quest_format", "STRING"),
        ("buying_model", "STRING"),
        ("reward_orbs", "INT64"),
        ("completion_threshold_seconds", "INT64"),
        ("required_playtime_minutes", "INT64"),
        ("bid_strategy", "STRING"),
        ("bid_amount_usd", "NUMERIC"),
        ("daily_budget_usd", "NUMERIC"),
        ("start_ts", "TIMESTAMP"),
        ("end_ts", "TIMESTAMP"),
        ("target_countries", "STRING"),
        ("target_platforms", "STRING"),
        ("target_server_categories", "STRING"),
        ("created_ts", "TIMESTAMP"),
    ],
    "ads_creatives": [
        ("creative_id", "STRING"),
        ("campaign_id", "STRING"),
        ("creative_format", "STRING"),
        ("duration_sec", "INT64"),
        ("created_ts", "TIMESTAMP"),
    ],
    "ads_device_identities": [
        ("device_id", "STRING"),
        ("platform", "STRING"),
        ("signed_in_account_id", "STRING"),
        ("device_ad_id", "STRING"),
        ("ip_prefix", "STRING"),
        ("ua_fingerprint", "STRING"),
        ("first_seen_ts", "TIMESTAMP"),
        ("last_seen_ts", "TIMESTAMP"),
        ("observed_sessions", "INT64"),
    ],
    "ads_requests": [
        ("request_id", "STRING"),
        ("request_ts", "TIMESTAMP"),
        ("user_id", "STRING"),
        ("device_id", "STRING"),
        ("server_id", "STRING"),
        ("placement", "STRING"),
        ("device_platform", "STRING"),
        ("country", "STRING"),
        ("eligible_campaign_count", "INT64"),
        ("ingest_ts", "TIMESTAMP"),
    ],
    "ads_auction_bids": [
        ("bid_id", "STRING"),
        ("request_id", "STRING"),
        ("campaign_id", "STRING"),
        ("creative_id", "STRING"),
        ("bid_cpm_usd", "NUMERIC"),
        ("predicted_ctr", "NUMERIC"),
        ("auction_score", "NUMERIC"),
        ("is_winner", "INT64"),
        ("ingest_ts", "TIMESTAMP"),
    ],
    "ads_impressions": [
        ("impression_id", "STRING"),
        ("request_id", "STRING"),
        ("campaign_id", "STRING"),
        ("creative_id", "STRING"),
        ("user_id", "STRING"),
        ("device_id", "STRING"),
        ("server_id", "STRING"),
        ("placement", "STRING"),
        ("impression_ts", "TIMESTAMP"),
        ("billable_amount_usd", "NUMERIC"),
        ("is_viewable", "INT64"),
        ("view_duration_ms", "INT64"),
        ("ingest_ts", "TIMESTAMP"),
    ],
    "ads_clicks": [
        ("click_id", "STRING"),
        ("impression_id", "STRING"),
        ("user_id", "STRING"),
        ("click_ts", "TIMESTAMP"),
        ("billable_amount_usd", "NUMERIC"),
        ("ingest_ts", "TIMESTAMP"),
    ],
    "ads_conversions": [
        ("conversion_id", "STRING"),
        ("user_id", "STRING"),
        ("conversion_device_id", "STRING"),
        ("advertiser_id", "STRING"),
        ("conversion_type", "STRING"),
        ("conversion_ts", "TIMESTAMP"),
        ("conversion_value_usd", "NUMERIC"),
        ("source_system", "STRING"),
        ("device_platform", "STRING"),
        ("ingest_ts", "TIMESTAMP"),
    ],
    "ads_quest_progress": [
        ("progress_id", "STRING"),
        ("impression_id", "STRING"),
        ("user_id", "STRING"),
        ("campaign_id", "STRING"),
        ("creative_id", "STRING"),
        ("quest_format", "STRING"),
        ("milestone", "STRING"),
        ("seconds_viewed", "INT64"),
        ("playtime_minutes", "INT64"),
        ("progress_pct", "NUMERIC"),
        ("orbs_granted", "INT64"),
        ("occurred_ts", "TIMESTAMP"),
        ("ingest_ts", "TIMESTAMP"),
    ],
    "ads_mmp_postbacks": [
        ("postback_id", "STRING"),
        ("mmp_name", "STRING"),
        ("feed_contract", "STRING"),
        ("advertiser_id", "STRING"),
        ("claimed_campaign_id", "STRING"),
        ("claimed_user_id", "STRING"),
        ("claimed_device_id", "STRING"),
        ("event_name", "STRING"),
        ("event_ts", "TIMESTAMP"),
        ("received_ts", "TIMESTAMP"),
        ("claimed_attribution_type", "STRING"),
        ("claimed_value_usd", "NUMERIC"),
    ],
}

TS_FMT = "%Y-%m-%d %H:%M:%S"


def sigmoid(x: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-x))


def fmt_ts(arr) -> np.ndarray:
    """Format a datetime64 array as warehouse-friendly text, preserving nulls."""
    s = pd.Series(pd.to_datetime(arr, errors="coerce"))
    return s.dt.strftime(TS_FMT).to_numpy()


class TableWriter:
    """Streams chunks to one gzipped CSV per table so memory stays flat."""

    def __init__(self, name: str) -> None:
        self.name = name
        self.columns = [c for c, _ in SCHEMAS[name]]
        folder = os.path.join(OUT_DIR, name)
        os.makedirs(folder, exist_ok=True)
        for stale in os.listdir(folder):
            os.remove(os.path.join(folder, stale))
        self.path = os.path.join(folder, "part-00000.csv.gz")
        self.handle = gzip.open(self.path, "wt", newline="")
        self.rows = 0
        self._wrote_header = False

    def write(self, df: pd.DataFrame) -> None:
        if df.empty:
            return
        missing = [c for c in self.columns if c not in df.columns]
        if missing:
            raise ValueError(f"{self.name}: generated frame is missing {missing}")
        df[self.columns].to_csv(self.handle, header=not self._wrote_header, index=False)
        self._wrote_header = True
        self.rows += len(df)

    def close(self) -> None:
        self.handle.close()


def load_universe() -> dict[str, pd.DataFrame]:
    """Read the committed engagement seeds; they define who exists and when."""
    need = ["raw_users", "raw_servers", "raw_server_joins", "raw_messages", "raw_voice_sessions",
            "raw_game_session_events"]
    out = {}
    for name in need:
        path = os.path.join(SEEDS_DIR, f"{name}.csv")
        if not os.path.exists(path):
            raise SystemExit(
                f"missing {path}. Run `python generate_events.py` first -- the ad feeds are "
                "generated against the existing user and server universe, not independently."
            )
        out[name] = pd.read_csv(path)
    return out


def build_entities(rng, universe, n_advertisers, n_campaigns, window_start, window_end):
    """Advertisers, campaigns with real targeting clauses, and their creatives."""
    countries = sorted(universe["raw_users"]["country"].unique().tolist())
    categories = sorted(universe["raw_servers"]["category"].unique().tolist())

    advertiser_ids = [f"adv_{i:04d}" for i in range(n_advertisers)]
    advertisers = pd.DataFrame(
        {
            "advertiser_id": advertiser_ids,
            "advertiser_name": [f"advertiser-{i:04d}" for i in range(n_advertisers)],
            "vertical": rng.choice(VERTICALS, size=n_advertisers),
            # Most advertisers on a newly opened self-serve auction are small; a few
            # are managed accounts and a handful buy reserved inventory directly.
            "advertiser_tier": rng.choice(ADVERTISER_TIERS, size=n_advertisers, p=[0.62, 0.28, 0.10]),
            "created_ts": fmt_ts([window_start] * n_advertisers),
        }
    )

    campaign_ids = [f"cmp_{i:05d}" for i in range(n_campaigns)]
    objective = rng.choice(OBJECTIVES, size=n_campaigns, p=[0.20, 0.25, 0.30, 0.25])
    strategy = rng.choice(BID_STRATEGIES, size=n_campaigns, p=[0.65, 0.35])

    # One quest format per campaign. A campaign does not mix a rewarded video with a
    # playtime quest: the reward rule, the funnel and the measurable completion event
    # are all different, so mixing them inside one campaign would make every
    # format-level rate uninterpretable.
    campaign_advertiser = rng.choice(advertiser_ids, size=n_campaigns)
    tier_by_advertiser = dict(zip(advertiser_ids, advertisers["advertiser_tier"]))
    tiers = np.array([tier_by_advertiser[a] for a in campaign_advertiser])

    quest_format = np.where(
        tiers == "reserve",
        "video_quest_reserve",
        rng.choice(["video_quest", "play_quest", "arena_quest"], size=n_campaigns, p=[0.55, 0.25, 0.20]),
    )
    # Reserved inventory is bought directly and does not clear through the auction.
    buying_model = np.where(tiers == "reserve", "reservation", "auction")

    reward_orbs = rng.choice([10, 25, 50, 100], size=n_campaigns, p=[0.35, 0.35, 0.20, 0.10])
    is_video = np.isin(quest_format, list(VIDEO_FORMATS))
    completion_threshold_seconds = np.where(
        quest_format == "video_quest", VIDEO_REWARD_SECONDS,
        np.where(quest_format == "video_quest_reserve", 0, 0),
    )
    required_playtime_minutes = np.where(
        is_video, 0, rng.integers(PLAY_REWARD_MINUTES[0], PLAY_REWARD_MINUTES[1] + 1, size=n_campaigns)
    )

    # A CPM bid is dollars per thousand impressions; a CPC bid is dollars per click.
    bid = np.where(strategy == "cpm", rng.uniform(2.0, 14.0, n_campaigns),
                   rng.uniform(0.15, 1.80, n_campaigns)).round(4)

    span_days = (window_end - window_start).days
    start_offset = rng.integers(0, max(span_days - 7, 1), size=n_campaigns)
    run_days = rng.integers(7, max(span_days, 8), size=n_campaigns)
    start_ts = np.array([window_start + pd.Timedelta(days=int(o)) for o in start_offset])
    end_ts = np.array(
        [min(s + pd.Timedelta(days=int(d)), window_end) for s, d in zip(start_ts, run_days)]
    )

    def target_clause(pool, p_all, lo, hi):
        """'ALL' means unrestricted; otherwise a pipe-delimited allow-list."""
        out = []
        for _ in range(n_campaigns):
            if rng.random() < p_all:
                out.append("ALL")
            else:
                k = int(rng.integers(lo, min(hi, len(pool)) + 1))
                out.append("|".join(sorted(rng.choice(pool, size=k, replace=False))))
        return out

    campaigns = pd.DataFrame(
        {
            "campaign_id": campaign_ids,
            "advertiser_id": campaign_advertiser,
            "campaign_name": [f"campaign-{i:05d}" for i in range(n_campaigns)],
            "objective": objective,
            "quest_format": quest_format,
            "buying_model": buying_model,
            "reward_orbs": reward_orbs,
            "completion_threshold_seconds": completion_threshold_seconds,
            "required_playtime_minutes": required_playtime_minutes,
            "bid_strategy": strategy,
            "bid_amount_usd": bid,
            "daily_budget_usd": rng.choice([250, 500, 1000, 2500, 5000], size=n_campaigns).astype(float),
            "start_ts": fmt_ts(start_ts),
            "end_ts": fmt_ts(end_ts),
            "target_countries": target_clause(countries, 0.35, 2, 5),
            "target_platforms": target_clause(["desktop", "mobile", "web"], 0.45, 1, 2),
            "target_server_categories": target_clause(categories, 0.40, 2, 4),
            "created_ts": fmt_ts(start_ts),
        }
    )

    creative_rows = []
    per_campaign = rng.integers(2, 5, size=n_campaigns)
    for cid, k, fmt in zip(campaign_ids, per_campaign, quest_format):
        for _ in range(int(k)):
            # Video quests carry a runtime; playtime quests do not have one.
            duration = int(rng.choice([15, 30, 60])) if fmt in VIDEO_FORMATS else 0
            creative_rows.append((f"crt_{len(creative_rows):06d}", cid, fmt, duration))
    creatives = pd.DataFrame(
        creative_rows, columns=["creative_id", "campaign_id", "creative_format", "duration_sec"]
    )
    creatives["created_ts"] = fmt_ts([window_start] * len(creatives))

    return advertisers, campaigns, creatives, start_ts, end_ts


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate synthetic ad delivery and measurement events.")
    ap.add_argument("--scale", type=float, default=4.0,
                    help="multiplier on ad requests per active user-day (default 4)")
    ap.add_argument("--requests-per-active-day", type=float, default=5.0)
    ap.add_argument("--advertisers", type=int, default=24)
    ap.add_argument("--campaigns", type=int, default=60)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    universe = load_universe()
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(SCHEMA_DIR, exist_ok=True)

    users = universe["raw_users"].reset_index(drop=True)
    servers = universe["raw_servers"].reset_index(drop=True)
    joins = universe["raw_server_joins"]

    # ---- the activity spine: ads only serve to users who were in the app ----
    msg = universe["raw_messages"]
    voice = universe["raw_voice_sessions"]
    games = universe["raw_game_session_events"]
    games = games[games["event_type"] == "game_session_started"]
    active = pd.concat(
        [
            pd.DataFrame({"user_id": msg["user_id"], "d": pd.to_datetime(msg["sent_ts"]).dt.normalize()}),
            pd.DataFrame({"user_id": voice["user_id"], "d": pd.to_datetime(voice["started_ts"]).dt.normalize()}),
            pd.DataFrame({"user_id": games["user_id"], "d": pd.to_datetime(games["event_ts"]).dt.normalize()}),
        ],
        ignore_index=True,
    ).drop_duplicates()

    window_start = active["d"].min()
    window_end = active["d"].max() + pd.Timedelta(days=1)

    # Per-user engagement intensity, standardized. This is the latent "how active is
    # this user" signal; the warehouse recomputes it from fct_user_engagement_daily
    # as a point-in-time feature, so the feature and the label share a real cause.
    intensity = (
        msg.groupby("user_id").size().reindex(users["user_id"]).fillna(0).to_numpy()
        + 3.0 * voice.groupby("user_id").size().reindex(users["user_id"]).fillna(0).to_numpy()
        + 2.0 * games.groupby("user_id").size().reindex(users["user_id"]).fillna(0).to_numpy()
    )
    eng_z = (intensity - intensity.mean()) / (intensity.std() or 1.0)

    user_index = {u: i for i, u in enumerate(users["user_id"])}
    user_country = users["country"].to_numpy()
    user_platform = users["signup_platform"].to_numpy()

    # Flat membership array + per-user offsets, so picking "a server this user is in"
    # is one vectorized index lookup instead of a groupby per request.
    joins_sorted = joins.sort_values("user_id")
    mem_user_idx = joins_sorted["user_id"].map(user_index).to_numpy()
    mem_server = joins_sorted["server_id"].to_numpy()
    order = np.argsort(mem_user_idx, kind="stable")
    mem_user_idx, mem_server = mem_user_idx[order], mem_server[order]
    mem_start = np.searchsorted(mem_user_idx, np.arange(len(users)), side="left")
    mem_count = np.searchsorted(mem_user_idx, np.arange(len(users)), side="right") - mem_start

    server_category = servers.set_index("server_id")["category"]
    categories = sorted(servers["category"].unique().tolist())
    countries = sorted(users["country"].unique().tolist())
    platforms = ["desktop", "mobile", "web"]

    # ---- devices and the signals an identity graph can actually observe -------
    # A person reaches the platform from more than one device, and the link between a
    # device and an account is only sometimes observable. A signed-out client has no
    # account id; a cleared advertising identifier leaves nothing deterministic; a
    # conversion can land on a different device from the one that saw the ad.
    #
    # What is emitted here is the *observable* signal, never the truth. The true
    # device-to-person mapping goes to a ground-truth file that is deliberately not
    # loaded, so the resolution models have to earn their matches and the precision of
    # the probabilistic ones can be measured rather than asserted.
    home_ip = [f"10.{int(rng.integers(0, 256))}.{int(rng.integers(0, 256))}" for _ in range(len(users))]
    dev_rows, dev_owner = [], []
    for ui in range(len(users)):
        for j in range(int(rng.integers(DEVICES_PER_USER[0], DEVICES_PER_USER[1]))):
            did = f"dev_{len(dev_rows):07d}"
            plat = user_platform[ui] if j == 0 else str(rng.choice(platforms))
            signed_in = rng.random() < SIGNED_IN_DEVICE_RATE
            has_adid = plat == "mobile" and rng.random() < MOBILE_AD_ID_RATE
            first = window_start + pd.Timedelta(days=int(rng.integers(0, max((window_end - window_start).days, 1))))
            dev_rows.append({
                "device_id": did,
                "platform": plat,
                # the deterministic link, present only when the client was signed in
                "signed_in_account_id": users["user_id"].iloc[ui] if signed_in else None,
                "device_ad_id": f"adid_{len(dev_rows):07d}" if has_adid else None,
                # devices in one household usually share a network prefix: the main
                # probabilistic signal, and on its own far too weak to match on
                "ip_prefix": home_ip[ui] if rng.random() < SHARED_IP_RATE
                             else f"10.{int(rng.integers(0, 256))}.{int(rng.integers(0, 256))}",
                "ua_fingerprint": f"ua_{plat}_{int(rng.integers(0, 40))}",
                "first_seen_ts": fmt_ts([first])[0],
                "last_seen_ts": fmt_ts([first + pd.Timedelta(days=int(rng.integers(1, 30)))])[0],
                "observed_sessions": int(rng.poisson(12) + 1),
            })
            dev_owner.append(ui)

    devices_df = pd.DataFrame(dev_rows)
    dev_ids = devices_df["device_id"].to_numpy()
    dev_owner = np.array(dev_owner)
    dev_order = np.argsort(dev_owner, kind="stable")
    dev_ids_sorted = dev_ids[dev_order]
    dev_owner_sorted = dev_owner[dev_order]
    dev_start = np.searchsorted(dev_owner_sorted, np.arange(len(users)), side="left")
    dev_count = np.searchsorted(dev_owner_sorted, np.arange(len(users)), side="right") - dev_start

    advertisers, campaigns, creatives, camp_start, camp_end = build_entities(
        rng, universe, args.advertisers, args.campaigns, window_start, window_end
    )
    n_camp = len(campaigns)

    # ---- targeting as boolean lookup matrices (dimension value x campaign) ----
    def clause_matrix(pool, clause_series):
        mat = np.zeros((len(pool), n_camp), dtype=bool)
        for c, clause in enumerate(clause_series):
            allowed = pool if clause == "ALL" else clause.split("|")
            for v in allowed:
                if v in pool:
                    mat[pool.index(v), c] = True
        return mat

    country_ok = clause_matrix(countries, campaigns["target_countries"])
    platform_ok = clause_matrix(platforms, campaigns["target_platforms"])
    category_ok = clause_matrix(categories, campaigns["target_server_categories"])

    camp_start_np = pd.to_datetime(campaigns["start_ts"]).to_numpy()
    camp_end_np = pd.to_datetime(campaigns["end_ts"]).to_numpy()
    camp_bid = campaigns["bid_amount_usd"].to_numpy(dtype=float)
    camp_strategy = campaigns["bid_strategy"].to_numpy()
    camp_buying = campaigns["buying_model"].to_numpy()
    camp_quest_format = campaigns["quest_format"].to_numpy()
    camp_reward_orbs = campaigns["reward_orbs"].to_numpy(dtype=int)
    camp_threshold_sec = campaigns["completion_threshold_seconds"].to_numpy(dtype=int)
    camp_required_min = campaigns["required_playtime_minutes"].to_numpy(dtype=int)
    camp_objective = campaigns["objective"].to_numpy()
    camp_advertiser = campaigns["advertiser_id"].to_numpy()
    camp_quality = rng.normal(0, 0.35, size=n_camp)   # latent per-campaign CTR effect

    crt_campaign_idx = creatives["campaign_id"].map(
        {c: i for i, c in enumerate(campaigns["campaign_id"])}
    ).to_numpy()
    crt_order = np.argsort(crt_campaign_idx, kind="stable")
    crt_campaign_idx = crt_campaign_idx[crt_order]
    crt_id = creatives["creative_id"].to_numpy()[crt_order]
    crt_format = creatives["creative_format"].to_numpy()[crt_order]
    crt_duration = creatives["duration_sec"].to_numpy(dtype=int)[crt_order]
    crt_start = np.searchsorted(crt_campaign_idx, np.arange(n_camp), side="left")
    crt_count = np.searchsorted(crt_campaign_idx, np.arange(n_camp), side="right") - crt_start

    fmt_effect_arr = np.array([FORMAT_EFFECT[f] for f in crt_format])

    # ---- expand active user-days into ad requests -------------------------
    lam = args.requests_per_active_day * args.scale
    n_per = rng.poisson(lam, size=len(active))
    keep = n_per > 0
    req_user = np.repeat(active["user_id"].to_numpy()[keep], n_per[keep])
    req_day = np.repeat(active["d"].to_numpy()[keep], n_per[keep])
    total_requests = len(req_user)
    print(f"active user-days: {len(active):,}  ->  ad requests: {total_requests:,}")

    writers = {name: TableWriter(name) for name in SCHEMAS}
    writers["ads_device_identities"].write(devices_df)
    writers["ads_advertisers"].write(advertisers)
    writers["ads_campaigns"].write(campaigns)
    writers["ads_creatives"].write(creatives)

    # (user, campaign) exposure counts drive creative fatigue across the whole run.
    fatigue: dict[int, int] = {}
    conv_records: list[pd.DataFrame] = []
    max_k = 6
    req_counter = 0

    for lo in range(0, total_requests, CHUNK_REQUESTS):
        hi = min(lo + CHUNK_REQUESTS, total_requests)
        n = hi - lo
        u_ids = req_user[lo:hi]
        u_idx = np.array([user_index[u] for u in u_ids])
        day = pd.to_datetime(req_day[lo:hi])

        secs = rng.integers(0, 86400, size=n)
        req_ts = day + pd.to_timedelta(secs, unit="s")

        # server the user is actually a member of
        pick = (mem_start[u_idx] + (rng.random(n) * np.maximum(mem_count[u_idx], 1)).astype(int))
        pick = np.clip(pick, 0, len(mem_server) - 1)
        srv = mem_server[pick]
        srv_cat = server_category.reindex(srv).to_numpy()

        dpick = np.clip(
            dev_start[u_idx] + (rng.random(n) * np.maximum(dev_count[u_idx], 1)).astype(int),
            0, len(dev_ids_sorted) - 1,
        )
        req_device = dev_ids_sorted[dpick]

        placement = rng.choice(PLACEMENTS, size=n, p=[0.30, 0.20, 0.10, 0.15, 0.25])
        platform = user_platform[u_idx]
        country = user_country[u_idx]

        c_idx = np.array([countries.index(c) for c in country])
        p_idx = np.array([platforms.index(p) for p in platform])
        g_idx = np.array([categories.index(c) for c in srv_cat])

        eligible = (
            country_ok[c_idx] & platform_ok[p_idx] & category_ok[g_idx]
            & (req_ts.to_numpy()[:, None] >= camp_start_np[None, :])
            & (req_ts.to_numpy()[:, None] <= camp_end_np[None, :])
        )
        elig_count = eligible.sum(axis=1)

        request_ids = np.array([f"req_{i:011d}" for i in range(req_counter, req_counter + n)])
        req_counter += n
        req_ingest = req_ts + pd.to_timedelta(rng.integers(1, 20, size=n), unit="s")

        writers["ads_requests"].write(
            pd.DataFrame(
                {
                    "request_id": request_ids,
                    "request_ts": fmt_ts(req_ts),
                    "user_id": u_ids,
                    "device_id": req_device,
                    "server_id": srv,
                    "placement": placement,
                    "device_platform": platform,
                    "country": country,
                    "eligible_campaign_count": elig_count,
                    "ingest_ts": fmt_ts(req_ingest),
                }
            )
        )

        # ---- auction: up to max_k eligible campaigns bid ------------------
        rand_mat = rng.random((n, n_camp))
        rand_mat[~eligible] = -1.0
        top = np.argsort(-rand_mat, axis=1)[:, :max_k]
        rows = np.repeat(np.arange(n), max_k)
        cols = top.reshape(-1)
        valid = rand_mat[rows, cols] > -1.0
        rows, cols = rows[valid], cols[valid]
        if len(rows) == 0:
            continue

        # one creative per bidding campaign
        cpick = crt_start[cols] + (rng.random(len(cols)) * np.maximum(crt_count[cols], 1)).astype(int)
        cpick = np.clip(cpick, 0, len(crt_id) - 1)

        bid_cpm = np.where(
            camp_strategy[cols] == "cpm",
            camp_bid[cols],
            camp_bid[cols] * 1000 * 0.02,   # CPC bid expressed as an eCPM for ranking
        ) * rng.normal(1.0, 0.05, size=len(cols)).clip(0.7, 1.3)

        fat = np.array([fatigue.get(int(u_idx[r]) * 100_000 + int(c), 0) for r, c in zip(rows, cols)])
        logit = (
            -5.00
            + fmt_effect_arr[cpick]
            + np.array([PLACEMENT_EFFECT[p] for p in placement[rows]])
            + np.array([PLATFORM_EFFECT[p] for p in platform[rows]])
            + 0.55 * eng_z[u_idx[rows]]
            + camp_quality[cols]
            - 0.12 * np.log1p(fat)
            + rng.normal(0, 0.25, size=len(cols))
        )
        true_ctr = np.clip(sigmoid(logit), 0.0005, 0.25)

        # The predicted CTR the auction ranks on is a noisy view of the truth --
        # a real model is never exact, and attribution has to survive that.
        predicted_ctr = np.clip(true_ctr * rng.normal(1.0, 0.30, size=len(cols)), 0.0002, 0.35)
        # Reserved inventory is sold directly, so it takes the slot ahead of any
        # auction bid rather than outbidding one. Modelled as priority rather than a
        # very high bid, because a reservation that merely bid high would still show
        # up in the bid landscape and distort every clearing-price statistic.
        is_reservation = camp_buying[cols] == "reservation"
        score = bid_cpm * predicted_ctr + np.where(is_reservation, 1e6, 0.0)

        # winner = highest score per request
        order_idx = np.lexsort((-score, rows))
        rows_s, cols_s = rows[order_idx], cols[order_idx]
        first_of_request = np.ones(len(rows_s), dtype=bool)
        first_of_request[1:] = rows_s[1:] != rows_s[:-1]
        is_winner = first_of_request.astype(int)

        cpick_s, bid_s = cpick[order_idx], bid_cpm[order_idx]
        pctr_s, score_s, ctr_s = predicted_ctr[order_idx], score[order_idx], true_ctr[order_idx]
        bid_ts = req_ts.to_numpy()[rows_s]

        writers["ads_auction_bids"].write(
            pd.DataFrame(
                {
                    "bid_id": [f"bid_{lo}_{i:08d}" for i in range(len(rows_s))],
                    "request_id": request_ids[rows_s],
                    "campaign_id": campaigns["campaign_id"].to_numpy()[cols_s],
                    "creative_id": crt_id[cpick_s],
                    "bid_cpm_usd": bid_s.round(4),
                    "predicted_ctr": pctr_s.round(6),
                    "auction_score": score_s.round(6),
                    "is_winner": is_winner,
                    "ingest_ts": fmt_ts(pd.to_datetime(bid_ts) + pd.to_timedelta(2, unit="s")),
                }
            )
        )

        # ---- impressions: winners that actually rendered ------------------
        w = is_winner == 1
        wr, wc = rows_s[w], cols_s[w]
        rendered = rng.random(w.sum()) > RENDER_FAILURE_RATE
        wr, wc = wr[rendered], wc[rendered]
        w_crt, w_bid, w_ctr = cpick_s[w][rendered], bid_s[w][rendered], ctr_s[w][rendered]
        m = len(wr)
        if m == 0:
            continue

        imp_ts = pd.to_datetime(req_ts.to_numpy()[wr]) + pd.to_timedelta(rng.integers(0, 4, size=m), unit="s")
        imp_ids = np.array([f"imp_{lo}_{i:08d}" for i in range(m)])
        # CPM campaigns are billed per impression; CPC campaigns are billed per click.
        imp_billable = np.where(camp_strategy[wc] == "cpm", w_bid / 1000.0, 0.0).round(6)
        viewable = (rng.random(m) > 0.18).astype(int)
        view_ms = (rng.exponential(2600, size=m) * viewable).astype(int)

        imp_df = pd.DataFrame(
            {
                "impression_id": imp_ids,
                "request_id": request_ids[wr],
                "campaign_id": campaigns["campaign_id"].to_numpy()[wc],
                "creative_id": crt_id[w_crt],
                "user_id": u_ids[wr],
                "device_id": req_device[wr],
                "server_id": srv[wr],
                "placement": placement[wr],
                "impression_ts": fmt_ts(imp_ts),
                "billable_amount_usd": imp_billable,
                "is_viewable": viewable,
                "view_duration_ms": view_ms,
                "ingest_ts": fmt_ts(imp_ts + pd.to_timedelta(rng.integers(2, 90, size=m), unit="s")),
            }
        )

        # planted duplicates: the collector re-delivers a small share of rows with
        # the same impression_id and a later ingest_ts. Deduplication is downstream.
        dup_mask = rng.random(m) < DUP_IMPRESSION_RATE
        if dup_mask.any():
            dups = imp_df[dup_mask].copy()
            dups["ingest_ts"] = fmt_ts(
                pd.to_datetime(dups["ingest_ts"]) + pd.to_timedelta(rng.integers(30, 600, size=len(dups)), unit="s")
            )
            imp_df = pd.concat([imp_df, dups], ignore_index=True)
        writers["ads_impressions"].write(imp_df)

        for r, c in zip(wr, wc):
            key = int(u_idx[r]) * 100_000 + int(c)
            fatigue[key] = fatigue.get(key, 0) + 1

        # ---- quest progress and the reward event ---------------------------
        # The reward is the point of a rewarded format, and what earns it differs by
        # format: a seconds threshold for video_quest, full completion for a reserve
        # buy, accumulated minutes for play and arena quests. Emitting the milestones
        # as events rather than storing a single completion flag is what lets the
        # warehouse answer where people drop out, which is the question a rewarded
        # product actually lives or dies on.
        fmt_arr = crt_format[w_crt]
        dur_arr = np.maximum(crt_duration[w_crt], 1)
        is_video = np.isin(fmt_arr, list(VIDEO_FORMATS))
        req_min = np.maximum(camp_required_min[wc], 1)
        thr_sec = camp_threshold_sec[wc]

        # how far through the quest the user got, correlated with engagement so the
        # ranking features can learn it
        comp_logit = (
            0.25
            + 0.45 * eng_z[u_idx[wr]]
            + np.where(fmt_arr == "video_quest", 0.50, 0.0)
            + np.where(fmt_arr == "video_quest_reserve", -0.45, 0.0)
            + rng.normal(0, 0.60, size=m)
        )
        progress_frac = np.clip(sigmoid(comp_logit) * rng.uniform(0.45, 1.30, size=m), 0.02, 1.0)

        seconds_viewed = np.where(is_video, np.rint(progress_frac * dur_arr), 0).astype(int)
        playtime_minutes = np.where(~is_video, np.rint(progress_frac * req_min * 1.25), 0).astype(int)

        rewarded = np.where(
            is_video,
            np.where(
                fmt_arr == "video_quest",
                seconds_viewed >= np.maximum(thr_sec, 1),   # threshold reward
                seconds_viewed >= dur_arr,                  # reserve: full completion
            ),
            playtime_minutes >= req_min,
        )

        # Progress percentage is derived from the seconds or minutes actually
        # recorded, not from the latent draw that produced them. Reporting a raw
        # fraction alongside a rounded seconds count lets the two disagree -- a
        # reserve quest can round up to a full view and still show 98% progress,
        # which then looks like a reward granted below its own threshold.
        progress_pct_final = np.clip(
            np.where(is_video, seconds_viewed / dur_arr, playtime_minutes / req_min), 0.0, 1.0
        )

        progress_rows = []
        prog_seq = 0

        def add_milestone(mask, milestone, offset_s, pct, orbs=0):
            nonlocal prog_seq
            k = int(mask.sum())
            if k == 0:
                return
            ts = pd.to_datetime(imp_ts.to_numpy()[mask]) + pd.to_timedelta(offset_s[mask], unit="s")
            progress_rows.append(pd.DataFrame({
                "progress_id": [f"qp_{lo}_{prog_seq}_{i:08d}" for i in range(k)],
                "impression_id": imp_ids[mask],
                "user_id": u_ids[wr[mask]],
                "campaign_id": campaigns["campaign_id"].to_numpy()[wc[mask]],
                "creative_id": crt_id[w_crt[mask]],
                "quest_format": fmt_arr[mask],
                "milestone": milestone,
                "seconds_viewed": seconds_viewed[mask],
                "playtime_minutes": playtime_minutes[mask],
                "progress_pct": np.round(pct[mask], 4),
                "orbs_granted": (camp_reward_orbs[wc[mask]] if orbs else np.zeros(k, dtype=int)),
                "occurred_ts": fmt_ts(ts),
                "ingest_ts": fmt_ts(ts + pd.to_timedelta(rng.integers(2, 45, size=k), unit="s")),
            }))
            prog_seq += 1

        vid_secs = seconds_viewed.astype(float)
        play_secs = playtime_minutes.astype(float) * 60.0
        elapsed = np.where(is_video, vid_secs, play_secs)

        add_milestone(is_video, "view_start", np.zeros(m), np.zeros(m))
        add_milestone(~is_video, "play_start", np.zeros(m), np.zeros(m))
        for q in (0.25, 0.50, 0.75):
            add_milestone(is_video & (progress_frac >= q), f"quartile_{int(q * 100)}",
                          elapsed * q, np.full(m, q))
        add_milestone(is_video & (seconds_viewed >= dur_arr), "view_complete",
                      elapsed, progress_pct_final)
        add_milestone(~is_video & rewarded, "playtime_threshold", elapsed, progress_pct_final)
        add_milestone(rewarded, "reward_granted", elapsed + 1, progress_pct_final, orbs=1)

        if progress_rows:
            writers["ads_quest_progress"].write(pd.concat(progress_rows, ignore_index=True))

        # ---- clicks --------------------------------------------------------
        # Completing a quest and collecting the reward is the strongest in-session
        # signal of intent there is, so it moves the click rate far more than any
        # creative attribute. A model trained without the completion feature is
        # guessing at the thing that matters most.
        clicked = rng.random(m) < np.clip(w_ctr * np.where(rewarded, 1.9, 0.45), 0.0, 0.9)
        k = int(clicked.sum())
        click_ts = pd.to_datetime(imp_ts.to_numpy()[clicked]) + pd.to_timedelta(
            rng.integers(1, 91, size=k), unit="s"
        )
        click_billable = np.where(camp_strategy[wc[clicked]] == "cpc", camp_bid[wc[clicked]], 0.0).round(6)
        click_df = pd.DataFrame(
            {
                "click_id": [f"clk_{lo}_{i:08d}" for i in range(k)],
                "impression_id": imp_ids[clicked],
                "user_id": u_ids[wr[clicked]],
                "click_ts": fmt_ts(click_ts),
                "billable_amount_usd": click_billable,
                "ingest_ts": fmt_ts(click_ts + pd.to_timedelta(rng.integers(2, 60, size=k), unit="s")),
            }
        )

        # planted orphans: a click whose impression was never logged. Joining these
        # away silently would understate clicks and hide a real tracking bug.
        n_orphan = int(max(1, m * ORPHAN_CLICK_RATE)) if m * ORPHAN_CLICK_RATE >= 1 else 0
        if n_orphan:
            oi = rng.integers(0, m, size=n_orphan)
            o_ts = pd.to_datetime(imp_ts.to_numpy()[oi]) + pd.to_timedelta(
                rng.integers(1, 120, size=n_orphan), unit="s"
            )
            click_df = pd.concat(
                [
                    click_df,
                    pd.DataFrame(
                        {
                            "click_id": [f"clk_{lo}_orph_{i:06d}" for i in range(n_orphan)],
                            "impression_id": [f"imp_missing_{lo}_{i:06d}" for i in range(n_orphan)],
                            "user_id": u_ids[wr[oi]],
                            "click_ts": fmt_ts(o_ts),
                            "billable_amount_usd": 0.0,
                            "ingest_ts": fmt_ts(o_ts + pd.to_timedelta(5, unit="s")),
                        }
                    ),
                ],
                ignore_index=True,
            )
        writers["ads_clicks"].write(click_df)

        # ---- conversions ---------------------------------------------------
        # Post-click: delay is exponential with a long tail, so a minority land
        # outside the 7-day click window and must come back unattributed.
        obj = camp_objective[wc[clicked]]
        base = np.array([OBJECTIVE_CONV_RATE[o] for o in obj])
        converts = rng.random(k) < base
        nc = int(converts.sum())
        if nc:
            delay_h = np.clip(rng.exponential(30.0, size=nc), 0.05, 480.0)
            # A deliberate long tail: about 2.5% of post-click conversions land seven
            # to twenty days after the click. Without them the click window is a
            # parameter nothing ever tests -- every conversion would fall inside any
            # plausible window, and widening or narrowing it would change no number.
            tail = rng.random(nc) < 0.025
            if tail.any():
                delay_h[tail] = rng.uniform(168.0, 480.0, size=int(tail.sum()))
            c_ts = pd.to_datetime(click_ts.to_numpy()[converts]) + pd.to_timedelta(delay_h, unit="h")
            ev = np.array([OBJECTIVE_EVENT[o] for o in obj[converts]])
            val = np.where(ev == "purchase", rng.lognormal(3.0, 0.8, size=nc), 0.0).round(2)
            conv_records.append(
                pd.DataFrame(
                    {
                        "user_id": u_ids[wr[clicked][converts]],
                        "serving_device_id": req_device[wr[clicked][converts]],
                        "advertiser_id": camp_advertiser[wc[clicked][converts]],
                        "conversion_type": ev,
                        "conversion_ts": c_ts,
                        "conversion_value_usd": val,
                        "truth_campaign_id": campaigns["campaign_id"].to_numpy()[wc[clicked][converts]],
                        "truth_touchpoint": "click",
                        "truth_impression_id": imp_ids[clicked][converts],
                        "device_platform": platform[wr[clicked][converts]],
                    }
                )
            )

        # View-through: saw it, never clicked, converted anyway. Shorter window.
        vt = (~clicked) & (rng.random(m) < VIEW_THROUGH_RATE * np.where(rewarded, 4.0, 1.0))
        nv = int(vt.sum())
        if nv:
            delay_h = np.clip(rng.exponential(10.0, size=nv), 0.05, 60.0)
            c_ts = pd.to_datetime(imp_ts.to_numpy()[vt]) + pd.to_timedelta(delay_h, unit="h")
            ev = np.array([OBJECTIVE_EVENT[o] for o in camp_objective[wc[vt]]])
            val = np.where(ev == "purchase", rng.lognormal(2.8, 0.8, size=nv), 0.0).round(2)
            conv_records.append(
                pd.DataFrame(
                    {
                        "user_id": u_ids[wr[vt]],
                        "serving_device_id": req_device[wr[vt]],
                        "advertiser_id": camp_advertiser[wc[vt]],
                        "conversion_type": ev,
                        "conversion_ts": c_ts,
                        "conversion_value_usd": val,
                        "truth_campaign_id": campaigns["campaign_id"].to_numpy()[wc[vt]],
                        "truth_touchpoint": "view",
                        "truth_impression_id": imp_ids[vt],
                        "device_platform": platform[wr[vt]],
                    }
                )
            )

    # ---- assemble conversions, add organic, write -------------------------
    conv = (
        pd.concat(conv_records, ignore_index=True)
        if conv_records
        else pd.DataFrame(columns=["user_id", "serving_device_id", "advertiser_id", "conversion_type", "conversion_ts",
                                   "conversion_value_usd", "truth_campaign_id", "truth_touchpoint",
                                   "truth_impression_id", "device_platform"])
    )

    # Organic conversions: real purchases with no ad touchpoint anywhere. The whole
    # point of an attribution model is to leave these uncredited.
    n_org = int(len(conv) * ORGANIC_CONV_SHARE / max(1 - ORGANIC_CONV_SHARE, 0.01)) if len(conv) else 0
    if n_org:
        oi = rng.integers(0, len(users), size=n_org)
        o_days = rng.integers(0, max((window_end - window_start).days, 1), size=n_org)
        o_ts = pd.to_datetime(window_start) + pd.to_timedelta(o_days, unit="D") + pd.to_timedelta(
            rng.integers(0, 86400, size=n_org), unit="s"
        )
        ev = rng.choice(["purchase", "signup", "install"], size=n_org, p=[0.45, 0.35, 0.20])
        conv = pd.concat(
            [
                conv,
                pd.DataFrame(
                    {
                        "user_id": users["user_id"].to_numpy()[oi],
                        "serving_device_id": dev_ids_sorted[
                            np.clip(dev_start[oi] + (rng.random(n_org) * np.maximum(dev_count[oi], 1)).astype(int),
                                    0, len(dev_ids_sorted) - 1)
                        ],
                        "advertiser_id": rng.choice(advertisers["advertiser_id"], size=n_org),
                        "conversion_type": ev,
                        "conversion_ts": o_ts,
                        "conversion_value_usd": np.where(
                            ev == "purchase", rng.lognormal(3.0, 0.9, size=n_org), 0.0
                        ).round(2),
                        "truth_campaign_id": None,
                        "truth_touchpoint": "organic",
                        "truth_impression_id": None,
                        "device_platform": user_platform[oi],
                    }
                ),
            ],
            ignore_index=True,
        )

    conv = conv.sort_values("conversion_ts").reset_index(drop=True)
    conv["conversion_id"] = [f"cnv_{i:010d}" for i in range(len(conv))]
    # Late arrival: median well under an hour, tail out to three days. This is why
    # the facts are incremental with a lookback rather than appended by event date.
    lag_h = np.clip(rng.lognormal(-0.7, 1.5, size=len(conv)), 0.01, 72.0)
    conv["ingest_ts"] = conv["conversion_ts"] + pd.to_timedelta(lag_h, unit="h")
    conv["source_system"] = "first_party_sdk"

    # ---- cross-device behaviour and identity loss -------------------------
    # A fifth of conversions happen on a different device from the one that saw the
    # ad: someone watches a quest on mobile and buys on desktop. Attribution that
    # joins on device alone misses every one of them.
    uidx_conv = conv["user_id"].map(user_index).to_numpy()
    serving_dev = conv["serving_device_id"].to_numpy(dtype=object)
    counts = np.maximum(dev_count[uidx_conv], 1)
    pos = dev_start[uidx_conv] + (rng.random(len(conv)) * counts).astype(int)
    # Drawing a device at random can land on the serving device again, which silently
    # halves the cross-device rate. Where it does, step to the next device in that
    # person's block so the alternative really is an alternative.
    collided = dev_ids_sorted[np.clip(pos, 0, len(dev_ids_sorted) - 1)] == serving_dev
    stepped = dev_start[uidx_conv] + ((pos - dev_start[uidx_conv] + 1) % counts)
    pos = np.where(collided, stepped, pos)
    alt_dev = dev_ids_sorted[np.clip(pos, 0, len(dev_ids_sorted) - 1)]

    # Only someone with more than one device can convert on a different one, so the
    # rate is defined over that population rather than over everyone.
    multi_device = dev_count[uidx_conv] > 1
    crossed = multi_device & (rng.random(len(conv)) < CROSS_DEVICE_CONVERSION_RATE)
    conv["conversion_device_id"] = np.where(crossed, alt_dev, serving_dev)

    # Some conversions arrive with no user identifier at all -- a signed-out client,
    # a cleared identifier, a partner that cannot pass one. The device is all that is
    # left. These rows are the whole reason an identity graph exists: without one they
    # are simply unattributable, and the spend that produced them looks wasted.
    identity_lost = rng.random(len(conv)) < UNIDENTIFIED_CONVERSION_RATE
    conv["observed_user_id"] = np.where(identity_lost, None, conv["user_id"].to_numpy(dtype=object))

    writers["ads_conversions"].write(
        pd.DataFrame(
            {
                "conversion_id": conv["conversion_id"],
                # the identifier as *observed*, which is sometimes nothing
                "user_id": conv["observed_user_id"],
                "conversion_device_id": conv["conversion_device_id"],
                "advertiser_id": conv["advertiser_id"],
                "conversion_type": conv["conversion_type"],
                "conversion_ts": fmt_ts(conv["conversion_ts"]),
                "conversion_value_usd": conv["conversion_value_usd"],
                "source_system": conv["source_system"],
                # Carried through so third-party parity can compare like with like:
                # the measurement partner only reports mobile install and purchase
                # events, so a first-party total that includes desktop would show a
                # permanent coverage "gap" that is really a scope mismatch.
                "device_platform": conv["device_platform"],
                "ingest_ts": fmt_ts(conv["ingest_ts"]),
            }
        )
    )

    # ---- third-party measurement postbacks --------------------------------
    # Shaped like an MMP postback: the vendor asserts its own attribution, arrives
    # late, sometimes twice, sometimes without a user identifier, and sometimes
    # credits a different campaign than first-party last-touch does. Reconciling
    # that disagreement is what mart_measurement_parity exists for.
    eligible_mmp = conv[
        conv["conversion_type"].isin(["install", "purchase"])
        & (conv["device_platform"] == "mobile")
    ].copy()
    reported = eligible_mmp[rng.random(len(eligible_mmp)) < MMP_COVERAGE].copy()

    all_campaign_ids = campaigns["campaign_id"].to_numpy()

    # Which partner reports each conversion. The two contracts are not
    # interchangeable: a mobile install-attribution feed and a gaming
    # engagement-measurement feed observe different things and disagree with us at
    # different rates, so partner is assigned first and every defect rate is
    # conditioned on it. Reporting one blended "third-party" number across both
    # would average away the only signal that tells you which vendor to call.
    partner = rng.choice(MMP_NAMES, size=len(reported), p=[0.6, 0.4])
    disagree_rate = np.where(partner == "gamesight_style",
                             MMP_CAMPAIGN_DISAGREE * 2.0, MMP_CAMPAIGN_DISAGREE)

    claimed_campaign = reported["truth_campaign_id"].to_numpy(dtype=object).copy()
    disagree = rng.random(len(reported)) < disagree_rate
    claimed_campaign[disagree] = rng.choice(all_campaign_ids, size=int(disagree.sum()))
    # organic conversions have no truth campaign; an MMP that reports them at all
    # is over-claiming, which is itself a parity signal worth seeing
    missing_truth = pd.isna(claimed_campaign)
    claimed_campaign[missing_truth] = rng.choice(all_campaign_ids, size=int(missing_truth.sum()))

    # The partner can only claim what it observed. Where first-party identity was
    # already lost, the postback cannot carry a user either -- and the partner drops a
    # further share of its own. The device identifier survives both, which is what
    # makes those postbacks recoverable rather than discarded.
    claimed_user = reported["observed_user_id"].to_numpy(dtype=object).copy()
    claimed_user[rng.random(len(reported)) < MMP_NULL_USER_RATE] = None
    claimed_device = reported["conversion_device_id"].to_numpy(dtype=object).copy()

    pb = pd.DataFrame(
        {
            "postback_id": [f"pb_{i:010d}" for i in range(len(reported))],
            "mmp_name": partner,
            "feed_contract": [MMP_CONTRACTS[m] for m in partner],
            "advertiser_id": reported["advertiser_id"].to_numpy(),
            "claimed_campaign_id": claimed_campaign,
            "claimed_user_id": claimed_user,
            "claimed_device_id": claimed_device,
            "event_name": reported["conversion_type"].to_numpy(),
            "event_ts": reported["conversion_ts"].to_numpy(),
            "claimed_attribution_type": np.where(
                reported["truth_touchpoint"].to_numpy() == "view", "view_through", "click_through"
            ),
            "claimed_value_usd": reported["conversion_value_usd"].to_numpy(),
        }
    )
    pb["received_ts"] = pd.to_datetime(pb["event_ts"]) + pd.to_timedelta(
        np.clip(rng.lognormal(0.2, 1.1, size=len(pb)), 0.02, 96.0), unit="h"
    )

    # MMP-only conversions: the vendor reports events we have no first-party record of
    n_only = int(len(pb) * MMP_ONLY_RATE)
    if n_only:
        only_partner = rng.choice(MMP_NAMES, size=n_only, p=[0.45, 0.55])
        oi = rng.integers(0, len(users), size=n_only)
        o_ts = pd.to_datetime(window_start) + pd.to_timedelta(
            rng.integers(0, max((window_end - window_start).days, 1), size=n_only), unit="D"
        ) + pd.to_timedelta(rng.integers(0, 86400, size=n_only), unit="s")
        only = pd.DataFrame(
            {
                "postback_id": [f"pb_only_{i:08d}" for i in range(n_only)],
                "mmp_name": only_partner,
                "feed_contract": [MMP_CONTRACTS[m] for m in only_partner],
                "advertiser_id": rng.choice(advertisers["advertiser_id"], size=n_only),
                "claimed_campaign_id": rng.choice(all_campaign_ids, size=n_only),
                "claimed_user_id": users["user_id"].to_numpy()[oi],
                "claimed_device_id": dev_ids_sorted[
                    np.clip(dev_start[oi] + (rng.random(n_only) * np.maximum(dev_count[oi], 1)).astype(int),
                            0, len(dev_ids_sorted) - 1)
                ],
                "event_name": rng.choice(["install", "purchase"], size=n_only),
                "event_ts": o_ts,
                "claimed_attribution_type": "click_through",
                "claimed_value_usd": rng.lognormal(2.9, 0.8, size=n_only).round(2),
            }
        )
        only["received_ts"] = pd.to_datetime(only["event_ts"]) + pd.to_timedelta(2, unit="h")
        pb = pd.concat([pb, only], ignore_index=True)

    # retransmissions: identical postback_id delivered twice
    dup = pb[rng.random(len(pb)) < MMP_DUP_RATE].copy()
    if len(dup):
        dup["received_ts"] = pd.to_datetime(dup["received_ts"]) + pd.to_timedelta(
            rng.integers(60, 3600, size=len(dup)), unit="s"
        )
        pb = pd.concat([pb, dup], ignore_index=True)

    writers["ads_mmp_postbacks"].write(
        pd.DataFrame(
            {
                "postback_id": pb["postback_id"],
                "mmp_name": pb["mmp_name"],
                "feed_contract": pb["feed_contract"],
                "advertiser_id": pb["advertiser_id"],
                "claimed_campaign_id": pb["claimed_campaign_id"],
                "claimed_user_id": pb["claimed_user_id"],
                "claimed_device_id": pb["claimed_device_id"],
                "event_name": pb["event_name"],
                "event_ts": fmt_ts(pb["event_ts"]),
                "received_ts": fmt_ts(pb["received_ts"]),
                "claimed_attribution_type": pb["claimed_attribution_type"],
                "claimed_value_usd": pb["claimed_value_usd"],
            }
        )
    )

    # ---- ground truth, for validating attribution (never loaded) ----------
    identity_truth = pd.DataFrame({
        "device_id": dev_ids_sorted,
        "true_user_id": users["user_id"].to_numpy()[dev_owner_sorted],
    })
    identity_truth.to_csv(
        os.path.join(OUT_DIR, "_ground_truth_identity.csv.gz"), index=False, compression="gzip"
    )

    truth_path = os.path.join(OUT_DIR, "_ground_truth_attribution.csv.gz")
    conv[["conversion_id", "user_id", "truth_campaign_id", "truth_touchpoint",
          "truth_impression_id", "conversion_ts"]].to_csv(truth_path, index=False, compression="gzip")

    # ---- schemas + manifest -----------------------------------------------
    for name, cols in SCHEMAS.items():
        with open(os.path.join(SCHEMA_DIR, f"{name}.json"), "w") as fh:
            json.dump(
                [{"name": c, "type": t, "mode": "NULLABLE"} for c, t in cols], fh, indent=2
            )

    counts = {name: w.rows for name, w in writers.items()}
    for w in writers.values():
        w.close()

    manifest = {
        "generated_at_utc": datetime.now(timezone.utc).strftime(TS_FMT),
        "seed": args.seed,
        "scale": args.scale,
        "requests_per_active_day": args.requests_per_active_day,
        "window_start": str(window_start),
        "window_end": str(window_end),
        "row_counts": counts,
        "total_rows": int(sum(counts.values())),
        "identity_rates": {
            "signed_in_devices": SIGNED_IN_DEVICE_RATE,
            "shared_ip": SHARED_IP_RATE,
            "mobile_ad_id": MOBILE_AD_ID_RATE,
            "cross_device_conversions": CROSS_DEVICE_CONVERSION_RATE,
            "unidentified_conversions": UNIDENTIFIED_CONVERSION_RATE,
        },
        "planted_anomaly_rates": {
            "duplicate_impressions": DUP_IMPRESSION_RATE,
            "orphan_clicks": ORPHAN_CLICK_RATE,
            "render_failures": RENDER_FAILURE_RATE,
            "view_through_conversions": VIEW_THROUGH_RATE,
            "organic_conversion_share": ORGANIC_CONV_SHARE,
            "mmp_coverage": MMP_COVERAGE,
            "mmp_campaign_disagreement": MMP_CAMPAIGN_DISAGREE,
            "mmp_null_user": MMP_NULL_USER_RATE,
            "mmp_duplicate_postbacks": MMP_DUP_RATE,
            "mmp_only_conversions": MMP_ONLY_RATE,
        },
    }
    with open(os.path.join(OUT_DIR, "_manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)

    print()
    for name, c in counts.items():
        print(f"  {name:<22} {c:>12,} rows")
    print(f"\n  total {manifest['total_rows']:,} rows -> {OUT_DIR}")
    print(f"  manifest: data/ads/_manifest.json   schemas: schemas/*.json")


if __name__ == "__main__":
    main()
