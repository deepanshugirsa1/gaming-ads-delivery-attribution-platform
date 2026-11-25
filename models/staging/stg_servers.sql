with source as (
    select * from {{ ref('raw_servers') }}
)

select
    cast(server_id as string)      as server_id,
    cast(owner_user_id as string)  as owner_user_id,
    cast(created_ts as timestamp)   as created_at,
    cast(created_ts as date)        as created_date,
    lower(cast(category as string)) as category
from source
