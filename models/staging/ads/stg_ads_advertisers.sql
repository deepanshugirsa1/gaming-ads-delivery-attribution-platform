with source as (
    select * from {{ ads_raw('ads_advertisers') }}
)

select
    cast(advertiser_id as string)      as advertiser_id,
    cast(advertiser_name as string)    as advertiser_name,
    lower(cast(vertical as string))    as vertical,
    -- How this advertiser buys: self_serve and managed compete in the auction,
    -- reserve buys inventory directly. The tier decides which marketplace a row
    -- belongs to, so nearly every delivery cut is wrong without it.
    lower(cast(advertiser_tier as string)) as advertiser_tier,
    cast(created_ts as timestamp)      as created_at
from source
