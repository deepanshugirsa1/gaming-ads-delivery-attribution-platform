with source as (
    select * from {{ ads_raw('ads_creatives') }}
)

select
    cast(creative_id as string)            as creative_id,
    cast(campaign_id as string)            as campaign_id,
    lower(cast(creative_format as string)) as creative_format,
    cast(duration_sec as int)              as duration_sec,
    cast(created_ts as timestamp)          as created_at
from source
