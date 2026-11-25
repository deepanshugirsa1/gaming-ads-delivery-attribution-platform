-- One row per device: who it resolves to, by what method, with what confidence.
--
-- The identity dimension every other model joins through. Devices that resolve to
-- nobody are kept, with the reason, because the unresolved population is the thing
-- you are trying to shrink and you cannot manage what you have filtered out.
--
-- devices_for_user lets a reader see the graph from the other side: a person resolving
-- to an implausible number of devices is the signature of a probabilistic rule that
-- has started over-matching, and it shows up here before it shows up in attribution.

with resolved as (
    select * from {{ ref('int_identity_resolved_devices') }}
),

per_user as (
    select
        resolved_user_id,
        count(*)                                                  as devices_for_user,
        sum(case when is_deterministic then 1 else 0 end)          as deterministic_devices_for_user
    from resolved
    where resolved_user_id is not null
    group by 1
)

select
    r.device_id,
    r.platform,
    r.ip_prefix,
    r.device_ad_id,
    r.has_advertising_id,
    r.first_seen_at,
    r.last_seen_at,
    r.observed_sessions,

    r.resolved_user_id,
    r.resolution_method,
    r.resolution_confidence,
    r.is_deterministic,
    r.resolved_user_id is not null              as is_resolved,
    r.corroborating_devices,
    r.candidate_user_count,

    coalesce(u.devices_for_user, 0)             as devices_for_user,
    coalesce(u.deterministic_devices_for_user, 0) as deterministic_devices_for_user,
    -- a person with devices but no signed-in one is held together entirely by
    -- inference, and every conversion credited through them rests on that
    (r.resolved_user_id is not null and coalesce(u.deterministic_devices_for_user, 0) = 0)
        as resolved_without_any_deterministic_anchor
from resolved r
left join per_user u on r.resolved_user_id = u.resolved_user_id
