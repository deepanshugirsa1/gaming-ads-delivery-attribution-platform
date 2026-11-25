with source as (
    select * from {{ ads_raw('ads_auction_bids') }}
)

select
    cast(bid_id as string)                   as bid_id,
    cast(request_id as string)               as request_id,
    cast(campaign_id as string)              as campaign_id,
    cast(creative_id as string)              as creative_id,
    cast(bid_cpm_usd as {{ decimal6() }})    as bid_cpm_usd,
    cast(predicted_ctr as {{ decimal6() }})  as predicted_ctr,
    cast(auction_score as {{ decimal6() }})  as auction_score,
    -- Booleans travel as 0/1 integers rather than text. BigQuery and DuckDB parse
    -- boolean literals from CSV differently enough that an integer plus an explicit
    -- comparison is the one spelling that cannot drift between the two.
    cast(is_winner as int) = 1               as is_winner,
    cast(ingest_ts as timestamp)             as ingested_at
from source
