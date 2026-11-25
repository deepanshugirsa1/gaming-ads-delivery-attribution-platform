with source as (
    select * from {{ ref('raw_game_session_events') }}
)

select
    cast(event_id as string)         as event_id,
    cast(game_session_id as string)  as game_session_id,
    cast(user_id as string)          as user_id,
    lower(cast(game_id as string))   as game_id,
    lower(cast(event_type as string)) as event_type,
    cast(event_ts as timestamp)       as event_at,
    cast(event_ts as date)            as event_date
from source
