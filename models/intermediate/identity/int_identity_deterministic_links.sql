-- Devices whose owner is known for certain, because the client was signed in.
--
-- This is the spine of the graph. Everything probabilistic below is anchored to these
-- rows, so their quality bounds the quality of the whole thing: a wrong deterministic
-- link does not just mis-attribute its own device, it propagates to every device that
-- shares a network with it.

select
    device_id,
    signed_in_account_id as resolved_user_id,
    platform,
    ip_prefix,
    ua_fingerprint,
    device_ad_id,
    first_seen_at,
    last_seen_at,
    observed_sessions
from {{ ref('stg_ads_device_identities') }}
where signed_in_account_id is not null
