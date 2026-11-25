-- Conversions with identity applied: the observed identifier where there is one, the
-- graph's resolution where there is not.
--
-- Applied once, here, so every downstream consumer agrees on who a conversion belongs
-- to. Doing it inside attribution instead would mean the conversion count and the
-- attributed count could resolve identity differently and quietly disagree.
--
-- is_identity_recovered marks the rows that exist in attribution only because the
-- graph found an owner. That flag is how the graph's value is measured rather than
-- assumed, and how a regression in it becomes visible.

with conversions as (
    select * from {{ ref('stg_ads_conversions') }}
),

devices as (
    select device_id, resolved_user_id, resolution_method, resolution_confidence
    from {{ ref('int_identity_resolved_devices') }}
)

select
    c.conversion_id,
    c.observed_user_id,
    c.conversion_device_id,
    d.resolved_user_id                          as device_resolved_user_id,
    coalesce(c.observed_user_id, d.resolved_user_id) as user_id,
    d.resolution_method                         as device_resolution_method,
    d.resolution_confidence                     as device_resolution_confidence,

    c.observed_user_id is not null              as had_observed_identity,
    (c.observed_user_id is null and d.resolved_user_id is not null)
                                                as is_identity_recovered,
    coalesce(c.observed_user_id, d.resolved_user_id) is null
                                                as is_unidentified,

    c.advertiser_id,
    c.conversion_type,
    c.converted_at,
    c.converted_date,
    c.conversion_value_usd,
    c.source_system,
    c.device_platform,
    c.ingested_at,
    c.ingest_lag_minutes
from conversions c
left join devices d on c.conversion_device_id = d.device_id
