with source as (
    select * from {{ ref('raw_messages') }}
)

select
    cast(message_id as string)   as message_id,
    cast(user_id as string)      as user_id,
    cast(server_id as string)    as server_id,
    cast(channel_id as string)   as channel_id,
    cast(sent_ts as timestamp)    as sent_at,
    cast(sent_ts as date)         as sent_date,
    cast(char_count as int)   as char_count
from source
