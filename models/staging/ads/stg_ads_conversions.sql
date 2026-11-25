with source as (
    select * from {{ ads_raw('ads_conversions') }}
)

select
    cast(conversion_id as string)                   as conversion_id,
    cast(user_id as string)                         as user_id,
    cast(advertiser_id as string)                   as advertiser_id,
    lower(cast(conversion_type as string))          as conversion_type,
    cast(conversion_ts as timestamp)                as converted_at,
    cast(conversion_ts as date)                     as converted_date,
    cast(conversion_value_usd as {{ decimal6() }})  as conversion_value_usd,
    lower(cast(source_system as string))            as source_system,
    lower(cast(device_platform as string))          as device_platform,
    cast(ingest_ts as timestamp)                    as ingested_at,
    -- How far behind the event its arrival was. This is the number that decides the
    -- incremental lookback window downstream: if conversions can arrive 72 hours
    -- late, a daily incremental that only rebuilds yesterday will permanently
    -- under-report, and no test on today's partition would ever notice.
    {{ dbt.datediff('cast(conversion_ts as timestamp)', 'cast(ingest_ts as timestamp)', 'minute') }}
        as ingest_lag_minutes
from source
