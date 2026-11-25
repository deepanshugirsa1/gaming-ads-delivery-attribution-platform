# Attribution Specification

What this project credits, to what, and why. Every rule here is implemented once,
in the model named beside it, and enforced by a test.

## Windows

| Setting | Value | Where |
|---|---|---|
| Click-through window | 7 days | `click_window_days` |
| View-through window | 1 day | `view_window_days` |
| Candidate collection — click | 28 days | `max_click_window_days` |
| Candidate collection — view | 7 days | `max_view_window_days` |

Candidates are collected at the **widest** window and the reported number is a filter
over them. Changing the reported window is then a config change and a rebuild of two
models, not a reprocess of history — and `mart_attribution_window_sensitivity` can
price every alternative window at once.

## What counts as a touchpoint

A **click** on a delivered impression, or a **view** of an impression that was not
clicked. A clicked impression contributes its click and not also a view; letting both
through would double-count one exposure and hand view-through credit to an impression
that already earned click credit.

Matching is on **user and advertiser**, never campaign. A conversion is an event at the
advertiser; which of their campaigns earns it is the question attribution answers, so
campaign cannot be in the join key.

## The priority rule (`int_ads_attribution_ranked`)

1. **A click outranks a view, always.** Someone who clicked and then converted is a
   stronger claim than someone who merely saw the ad, even if the view came later.
   Without this, a later banner view steals credit from the click that drove the visit.
2. **Among touchpoints of the same type, the most recent wins.** Last-touch.
3. **Ties break on `touchpoint_id`.** Without a deterministic final tie-break, two runs
   over identical data can credit different campaigns — a number that cannot be
   reproduced cannot be defended when an advertiser disputes it.

## Multi-touch

`linear_credit` = 1 / (in-window touchpoints), computed alongside last-touch in the same
model. Credits for one conversion sum to exactly 1, asserted by
`assert_linear_credit_sums_to_one`. `mart_multi_touch_comparison` quantifies, per
campaign, how much credit last-touch moves from introducers to closers.

## Three outcomes, not two

`fct_attributed_conversions` holds every conversion exactly once with an
`attribution_outcome`:

- `attributed` — a touchpoint inside the window earned it.
- `touchpoint_outside_window` — an ad was seen or clicked, but too long before. This is
  an argument for a wider window, not evidence the ad did nothing.
- `no_touchpoint` — organic demand, with no ad exposure at all in even the 28-day
  candidate window.

An inner join to the winning touchpoint would delete the last two categories and make
attributed conversions look like all conversions, reporting ad effectiveness as 100%.

## Reporting date

`agg_campaign_performance_daily` counts attributed conversions on the **touchpoint**
date, not the conversion date, so spend and the result it produced land on the same
row. The cost: recent rows are incomplete until the window closes, which the
`is_window_closed` flag states directly. `conversions_occurred_on_date` keeps the
conversion-dated view for anyone who needs it.

Parity is the exception — see below.

## Third-party parity (`mart_measurement_parity`)

Three decisions make the comparison honest, and each one, done wrong, produces a
convincing artefact instead of a finding.

1. **Both sides counted on the conversion date.** The partner reports event dates and
   knows nothing about our auctions. Touchpoint-dated first-party counts would be
   comparing two different calendars.
2. **Scope matched explicitly**: mobile only, install and purchase only. That is all the
   partner observes. Comparing their mobile installs against our all-platform,
   all-event total shows a permanent ~60% "undercount" that is pure scope mismatch.
3. **Postbacks with no user identifier are excluded and counted separately.** They are
   real conversions the partner saw but cannot tie to a user — a known unknown that
   belongs in neither side of the variance.

A campaign-day is flagged only when the variance exceeds `parity_tolerance_pct` **and**
the volume clears `min_conversions_for_parity_flag`. Two conversions against three is a
50% gap and means nothing; flagging it teaches people to ignore the alert.

The two partner feeds are **not interchangeable**: a mobile install-attribution contract
and a gaming engagement-measurement contract observe different things and disagree at
different rates, so `mart_mmp_surface_health` reports per contract. When parity breaches,
that table says whether to investigate our attribution or email the vendor.

## What attribution cannot tell you

`scripts/validate_attribution.py` reports the rate at which **organic conversions are
credited to ads** — users who would have converted anyway but saw an ad inside the
window. Attribution cannot separate influence from coincidence; only an experiment can.
That rate is the honest ceiling on every number in this project.
