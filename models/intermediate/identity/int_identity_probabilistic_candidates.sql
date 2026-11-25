-- Candidate owners for devices with no account link, inferred from shared signals.
--
-- The only real signal available is that devices on one network tend to belong to one
-- household, so an unlinked device is matched to the owner of deterministically
-- resolved devices sharing its network prefix. That is a weak signal on its own, which
-- is why it is scored rather than accepted, and why the score is built from named
-- components that can each be argued with:
--
--   0.50  base: shares a network prefix with a known device
--   0.20  the platforms agree
--   0.15  the devices were seen in overlapping windows
--   up to 0.10  more than one corroborating device on that network
--
-- Capped below 1.0 by construction. A probabilistic match must never be able to score
-- as high as a deterministic one, however much evidence accumulates -- the two are
-- different kinds of claim, and collapsing them is how a graph starts quietly
-- inventing people.
--
-- The ambiguity count is the important column. A network with two different known
-- owners cannot tell us which one an unlinked device belongs to, and guessing would
-- attribute one person's conversions to another. Those devices are left unresolved
-- downstream, deliberately.

with unlinked as (
    select *
    from {{ ref('stg_ads_device_identities') }}
    where signed_in_account_id is null
),

known as (
    select * from {{ ref('int_identity_deterministic_links') }}
),

paired as (
    select
        u.device_id,
        u.platform,
        u.ip_prefix,
        u.first_seen_at,
        u.last_seen_at,
        k.resolved_user_id                                          as candidate_user_id,
        count(*)                                                    as corroborating_devices,
        max(case when k.platform = u.platform then 1 else 0 end)    as platform_matches,
        max(case
                when k.first_seen_at <= u.last_seen_at
                 and k.last_seen_at >= u.first_seen_at
                then 1 else 0
            end)                                                    as windows_overlap
    from unlinked u
    join known k
        on u.ip_prefix = k.ip_prefix
    group by 1, 2, 3, 4, 5, 6
),

scored as (
    select
        *,
        0.50
          + 0.20 * platform_matches
          + 0.15 * windows_overlap
          + least(0.10, 0.02 * corroborating_devices) as match_confidence
    from paired
),

ranked as (
    select
        *,
        count(*) over (partition by device_id)        as candidate_user_count,
        row_number() over (
            partition by device_id
            order by match_confidence desc, candidate_user_id asc
        ) as candidate_rank
    from scored
)

select
    device_id,
    platform,
    ip_prefix,
    candidate_user_id,
    corroborating_devices,
    platform_matches = 1   as platform_matches,
    windows_overlap = 1    as windows_overlap,
    match_confidence,
    candidate_user_count,
    candidate_rank,
    candidate_user_count > 1 as is_ambiguous
from ranked
where candidate_rank = 1
