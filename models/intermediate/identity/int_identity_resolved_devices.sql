-- One row per device with its resolved owner, the method, and the confidence.
--
-- Deterministic links are taken as given at confidence 1.0. A probabilistic candidate
-- is accepted only when it is unambiguous *and* clears identity_min_confidence; one
-- that fails either test is recorded with the reason rather than dropped, because
-- "we could not tell" and "we never saw a signal" are different problems with
-- different fixes.
--
-- The asymmetry is deliberate: crediting one person's conversion to another is a
-- worse failure than leaving it unattributed. An unattributed conversion understates
-- a campaign; a misattributed one overstates a different campaign and corrupts the
-- training labels a ranker learns from.

{% set min_conf = var('identity_min_confidence') %}

with devices as (
    select * from {{ ref('stg_ads_device_identities') }}
),

deterministic as (
    select device_id, resolved_user_id
    from {{ ref('int_identity_deterministic_links') }}
),

probabilistic as (
    select * from {{ ref('int_identity_probabilistic_candidates') }}
)

select
    d.device_id,
    d.platform,
    d.ip_prefix,
    d.device_ad_id,
    d.has_advertising_id,
    d.first_seen_at,
    d.last_seen_at,
    d.observed_sessions,

    case
        when det.resolved_user_id is not null then det.resolved_user_id
        when p.candidate_user_id is not null
             and not p.is_ambiguous
             and p.match_confidence >= {{ min_conf }}
            then p.candidate_user_id
    end as resolved_user_id,

    case
        when det.resolved_user_id is not null then 'deterministic'
        when p.candidate_user_id is not null
             and not p.is_ambiguous
             and p.match_confidence >= {{ min_conf }}
            then 'probabilistic'
        when p.is_ambiguous then 'ambiguous'
        when p.candidate_user_id is not null then 'below_threshold'
        else 'no_signal'
    end as resolution_method,

    case
        when det.resolved_user_id is not null then 1.0
        else p.match_confidence
    end as resolution_confidence,

    coalesce(p.corroborating_devices, 0)   as corroborating_devices,
    coalesce(p.candidate_user_count, 0)    as candidate_user_count,
    det.resolved_user_id is not null       as is_deterministic
from devices d
left join deterministic det on d.device_id = det.device_id
left join probabilistic p on d.device_id = p.device_id
