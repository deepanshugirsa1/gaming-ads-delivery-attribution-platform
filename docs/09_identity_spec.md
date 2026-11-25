# Identity Resolution Specification

Attribution needs to know *who* converted. The platform does not always know.

A person reaches it from more than one device; a client can be signed out; an
advertising identifier can be cleared; a conversion can land on a different device from
the one that saw the ad; a measurement partner can pass a device and no user. Every one
of those breaks the join that attribution depends on, and the conversions they break are
invisible — they do not error, they simply never match, and the spend that produced them
looks wasted.

## What the warehouse observes

`ads_device_identities` has **no user column**. Whether a device belongs to a person is
the question the graph answers, not an input it is given. The observable signals are:

| Signal | Strength | Coverage |
|---|---|---|
| `signed_in_account_id` | deterministic | ~70% of devices |
| `device_ad_id` | strong, but only on mobile | ~80% of mobile |
| `ip_prefix` | weak on its own | all |
| `ua_fingerprint`, platform, seen window | corroborating only | all |

## Resolution

**Deterministic** — the client was signed in, so the account is observed. Confidence
1.0. This is the spine: every probabilistic match is anchored to these rows, so a wrong
deterministic link does not merely mis-resolve its own device, it propagates to every
device sharing that network.

**Probabilistic** — for a device with no account link, candidate owners are the people
who own deterministically resolved devices on the same network prefix. Scored from
named components:

```
0.50  shares a network prefix with a known device
0.20  the platforms agree
0.15  the devices were seen in overlapping windows
0.10  (max) more than one corroborating device on that network
```

Capped below 1.0 by construction. A probabilistic match must never score as high as a
deterministic one however much evidence accumulates — they are different kinds of claim,
and collapsing the distinction is how a graph starts inventing people.

Accepted only when **unambiguous** and at or above `identity_min_confidence` (0.60), so
a bare network match at 0.50 never resolves on its own.

**Unresolved**, with the reason recorded — and the three reasons have different owners:

- `ambiguous` — two different known people on one network. A modelling limit; no signal
  here separates them.
- `below_threshold` — a candidate exists but did not clear the floor. A tuning decision
  we made and can revisit.
- `no_signal` — nothing to go on. A collection gap, and the only one an engineering
  change fixes.

## The asymmetry that drives every threshold

**Crediting one person's conversion to another is worse than leaving it unattributed.**

An unattributed conversion understates one campaign. A misattributed one *also*
overstates a different campaign, and poisons the training labels a ranker learns from —
so the error compounds into the model rather than staying in a report. That is why the
confidence floor errs toward leaving devices unresolved, why ambiguous networks are never
guessed, and why `validate_identity.py` fails the build on precision rather than on
coverage.

Coverage rises trivially by lowering the threshold. The pair of numbers only means
anything together.

## Measured against ground truth

The generator knows which person each device belongs to and writes it to
`data/ads/_ground_truth_identity.csv.gz`, which is **deliberately never loaded**. The
models earn every match from observable signals alone, and
`scripts/validate_identity.py` scores them:

- **Deterministic precision must be exactly 1.0.** Anything less means the observed link
  is being read or joined wrongly, and it would propagate.
- **Probabilistic precision** must clear 80%, configurable. This is the number that
  decides whether the rule is worth running at all.
- Coverage is reported, never optimised alone.

## Where resolution is applied

Once, in `int_ads_conversions_resolved`: the observed identifier where there is one, the
graph's resolution where there is not. Doing it inside attribution instead would let the
conversion count and the attributed count resolve identity differently and disagree.

`fct_mmp_postbacks` applies the same graph to `claimed_device_id`, recovering postbacks
the partner could not attribute — which would otherwise appear as an unexplainable
parity gap rather than a known identity problem.

## What it is worth

`mart_identity_attribution_impact` reports, per day: conversions that arrived with an
identity, conversions recovered by the graph, conversions still unidentified, and
attribution coverage with and without.

`attribution_coverage_without_graph` is an **explicit counterfactual**, not a
measurement: a conversion attributed through a recovered identity might have been
attributed anyway had the identifier been present. It is an upper bound on the graph's
contribution and is labelled as one.

## Invariants (enforced by tests)

- `assert_ambiguous_devices_are_never_resolved`
- `assert_probabilistic_never_scores_as_deterministic`
- `assert_recovered_identity_has_a_resolved_device`
- `assert_unidentified_conversions_are_never_attributed`

## What this does not do

No cross-platform graph beyond the household heuristic, no identifier hashing or
clean-room matching, no consent or deletion propagation, and no decay — a device
resolved once stays resolved regardless of how stale the evidence is. All four matter in
production. The last is the one that would bite first.
