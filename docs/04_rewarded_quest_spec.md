# Rewarded Quest Specification

The ad formats modelled here are **rewarded**: the user is given something for
engaging, and the reward is earned by meeting a condition. That single fact changes the
data model more than any other decision in this project.

These formats are modelled on **publicly described** rewarded ad products. Nothing here
reflects any internal system, and all data is synthetic.

## Formats and what earns the reward

| Format | Reward rule | Modelled on |
|---|---|---|
| `video_quest` | a seconds threshold (default 15) | mobile-first rewarded video |
| `video_quest_reserve` | **full** video completion | reservation-bought premium placement |
| `play_quest` | accumulated minutes in a sponsored game | play-to-earn quest |
| `arena_quest` | accumulated minutes, playtime-weighted | time-in-game quest |

The reward rule is not cosmetic. A format that pays out partway through a view and one
that pays out only at 100% produce completely different funnels, and their completion
rates are not comparable numbers. **Format is therefore in the grain of every rate**, and
`agg_quest_funnel_daily` never divides a numerator from one format by a denominator from
another.

## Milestones as events

`ads_quest_progress` emits one row per milestone reached:

`view_start` · `play_start` · `quartile_25` · `quartile_50` · `quartile_75` ·
`view_complete` · `playtime_threshold` · `reward_granted`

Stored as events, not as flags on the impression, because the question a rewarded format
actually has to answer is **where people stop**. A completion flag tells you how many
finished. A milestone stream tells you that one format loses half its users before the
second quartile and another loses them after the third — the difference between a number
and a decision.

`progress_pct` is derived from the seconds or minutes actually recorded, never from the
underlying draw. Reporting a raw fraction beside a rounded seconds count lets the two
disagree, and a reserve quest can then round up to a full view while still showing 98%
progress — which reads as a reward granted below its own threshold.

## Invariants (enforced by tests)

- **No reward below its format's threshold** — `assert_reward_never_granted_below_threshold`.
  A reward granted early is value the advertiser did not buy; granted late, a user who
  earned nothing for finishing. Both are visible to users immediately.
- **Monotonic funnel** — `assert_quest_funnel_is_monotonic`. Completing without passing
  the third quartile means milestones are dropped or out of order.
- **Every impression has exactly one quest row** — `assert_every_impression_has_a_quest_row`.
  Impressions that produced no milestones are kept with `did_start = false`; dropping
  them would inflate every completion rate by shrinking the denominator.

## Auction versus reserved inventory

Reservation campaigns are bought directly and **take the slot ahead of the auction**
rather than outbidding it. Modelled as priority, not as a very high bid — a reservation
that merely bid high would appear in the bid landscape and distort every clearing-price
statistic.

`mart_auction_landscape_daily` therefore reports reserved inventory separately, and cuts
win rate by **advertiser tier** (`self_serve`, `managed`, `reserve`). When an auction
opens to self-serve buyers, the question that decides whether the marketplace is healthy
is whether small advertisers can win anything. A rising `avg_competing_bids` with a
falling `win_rate` for one tier is that tier being squeezed out, and it will churn its
advertisers long before it shows up in a revenue report.

`mart_budget_pacing_daily` tracks spend against daily budget for auction campaigns, with
reservations flagged rather than excluded — they are not paced against a budget at all,
so averaging them in understates how hard the auction campaigns are spending.

## Why completion matters to ranking

Finishing a rewarded quest is a deliberate act; an impression is not. The generator makes
click probability depend strongly on whether the reward was earned, and the feature
tables carry `campaign_prior_7d_reward_rate` and
`user_campaign_prior_7d_rewarded_quests` as of the request day. A ranker trained without
the completion signal is guessing at the thing that matters most on this product.
