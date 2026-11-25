with source as (
    select * from {{ ads_raw('ads_mmp_postbacks') }}
)

-- Third-party measurement postbacks, as received. Every field the partner asserts
-- is prefixed `claimed_` on purpose: this table is one party's opinion about what
-- happened, not a fact about our delivery. Keeping that distinction in the column
-- names is what stops a downstream model from quietly treating a partner's
-- attribution as ground truth.
select
    cast(postback_id as string)                      as postback_id,
    lower(cast(mmp_name as string))                  as mmp_name,
    -- Mobile install attribution and gaming engagement measurement are different
    -- contracts that observe different things. Keeping the shape on every row stops
    -- the two being averaged into one meaningless "third-party" number.
    lower(cast(feed_contract as string))             as feed_contract,
    cast(advertiser_id as string)                    as advertiser_id,
    cast(claimed_campaign_id as string)              as claimed_campaign_id,
    cast(claimed_user_id as string)                  as claimed_user_id,
    cast(claimed_device_id as string)                as claimed_device_id,
    lower(cast(event_name as string))                as event_name,
    cast(event_ts as timestamp)                      as event_at,
    cast(event_ts as date)                           as event_date,
    cast(received_ts as timestamp)                   as received_at,
    -- Same instant as received_at. The pipeline-health registry reads ingested_at
    -- on every feed; this partner feed names its arrival received_ts.
    cast(received_ts as timestamp)                   as ingested_at,
    lower(cast(claimed_attribution_type as string))  as claimed_attribution_type,
    cast(claimed_value_usd as {{ decimal6() }})      as claimed_value_usd,
    {{ dbt.datediff('cast(event_ts as timestamp)', 'cast(received_ts as timestamp)', 'minute') }}
        as receive_lag_minutes,
    claimed_user_id is null                          as is_unidentified_user
from source
