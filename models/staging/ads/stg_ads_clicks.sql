with source as (
    select * from {{ ads_raw('ads_clicks') }}
)

select
    cast(click_id as string)                      as click_id,
    cast(impression_id as string)                 as impression_id,
    cast(user_id as string)                       as user_id,
    cast(click_ts as timestamp)                   as clicked_at,
    cast(click_ts as date)                        as clicked_date,
    {{ dbt.date_trunc('hour', 'cast(click_ts as timestamp)') }} as clicked_hour,
    cast(billable_amount_usd as {{ decimal6() }}) as billable_amount_usd,
    cast(ingest_ts as timestamp)                  as ingested_at
from source
