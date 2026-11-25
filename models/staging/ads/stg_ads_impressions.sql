with source as (
    select * from {{ ads_raw('ads_impressions') }}
)

-- One row per delivered impression *as logged*, including the collector's duplicate
-- retransmissions. Deduplication happens in int_ads_impressions_deduped, not here,
-- so the raw duplicate rate stays observable and can be monitored rather than
-- silently disappearing at the first transformation.
select
    cast(impression_id as string)                 as impression_id,
    cast(request_id as string)                    as request_id,
    cast(campaign_id as string)                   as campaign_id,
    cast(creative_id as string)                   as creative_id,
    cast(user_id as string)                       as user_id,
    cast(server_id as string)                     as server_id,
    lower(cast(placement as string))              as placement,
    cast(impression_ts as timestamp)              as impressed_at,
    cast(impression_ts as date)                   as impressed_date,
    {{ dbt.date_trunc('hour', 'cast(impression_ts as timestamp)') }} as impressed_hour,
    cast(billable_amount_usd as {{ decimal6() }}) as billable_amount_usd,
    cast(is_viewable as int) = 1                  as is_viewable,
    cast(view_duration_ms as int)                 as view_duration_ms,
    cast(ingest_ts as timestamp)                  as ingested_at
from source
