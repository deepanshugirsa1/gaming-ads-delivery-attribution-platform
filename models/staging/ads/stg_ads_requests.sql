with source as (
    select * from {{ ads_raw('ads_requests') }}
)

select
    cast(request_id as string)             as request_id,
    cast(request_ts as timestamp)          as requested_at,
    cast(request_ts as date)               as requested_date,
    {{ dbt.date_trunc('hour', 'cast(request_ts as timestamp)') }} as requested_hour,
    cast(user_id as string)                as user_id,
    cast(device_id as string)              as device_id,
    cast(server_id as string)              as server_id,
    lower(cast(placement as string))       as placement,
    lower(cast(device_platform as string)) as device_platform,
    upper(cast(country as string))         as country,
    cast(eligible_campaign_count as int)   as eligible_campaign_count,
    cast(ingest_ts as timestamp)           as ingested_at
from source
