with source as (
    select * from {{ ads_raw('ads_device_identities') }}
)

-- One row per device, carrying only what is *observable* about it.
--
-- There is no user column here on purpose. Whether a device belongs to a person is the
-- question the identity graph answers, not an input it is given. The only deterministic
-- link available is signed_in_account_id, and it is null for roughly a third of devices
-- -- signed-out clients, which is exactly the population that makes identity hard.
select
    cast(device_id as string)                   as device_id,
    lower(cast(platform as string))             as platform,
    cast(signed_in_account_id as string)        as signed_in_account_id,
    cast(device_ad_id as string)                as device_ad_id,
    cast(ip_prefix as string)                   as ip_prefix,
    cast(ua_fingerprint as string)              as ua_fingerprint,
    cast(first_seen_ts as timestamp)            as first_seen_at,
    cast(last_seen_ts as timestamp)             as last_seen_at,
    cast(observed_sessions as int)              as observed_sessions,
    signed_in_account_id is not null            as has_account_link,
    device_ad_id is not null                    as has_advertising_id
from source
