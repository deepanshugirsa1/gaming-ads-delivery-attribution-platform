with source as (
    select * from {{ ref('raw_users') }}
)

select
    cast(user_id as string)            as user_id,
    cast(signup_ts as timestamp)        as signup_at,
    cast(signup_ts as date)             as signup_date,
    lower(cast(country as string))     as country,
    lower(cast(signup_platform as string)) as signup_platform
from source
