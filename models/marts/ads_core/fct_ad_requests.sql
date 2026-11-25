{{ config(
    materialized = 'incremental',
    unique_key = 'request_id',
    incremental_strategy = 'merge' if target.type == 'bigquery' else 'delete+insert',
    partition_by = {'field': 'requested_date', 'data_type': 'date'} if target.type == 'bigquery' else none,
    cluster_by = ['placement', 'country'] if target.type == 'bigquery' else none
) }}

-- One row per ad request: an opportunity to serve, whether or not anything served.
--
-- This is the denominator table. Fill rate, win rate, and every "why did we not
-- monetize this session" question start here, which is why unfilled requests are
-- first-class rows rather than absences. A warehouse that only stores impressions
-- can never explain the inventory it failed to sell.
--
-- Partitioned by request date and clustered on the two columns nearly every delivery
-- query filters on. The incremental filter keys off ingest time rather than event
-- time, because an event that arrives late still has to land: filtering on
-- requested_date would permanently skip anything delivered after its own day closed.

with requests as (
    select * from {{ ref('stg_ads_requests') }}

    {% if is_incremental() %}
    where ingested_at >= (
        select coalesce(
            {{ dbt.dateadd('day', '-' ~ var('incremental_lookback_days'), 'max(ingested_at)') }},
            cast('1970-01-01' as timestamp)
        )
        from {{ this }}
    )
    {% endif %}
),

bids as (
    select
        request_id,
        count(*)            as bid_count,
        max(auction_score)  as winning_auction_score
    from {{ ref('stg_ads_auction_bids') }}
    group by 1
),

impressions as (
    select
        request_id,
        campaign_id as winning_campaign_id,
        creative_id as winning_creative_id,
        impression_id
    from {{ ref('int_ads_impressions_deduped') }}
)

select
    r.request_id,
    r.requested_at,
    r.requested_date,
    r.requested_hour,
    r.user_id,
    r.server_id,
    r.placement,
    r.device_platform,
    r.country,
    r.eligible_campaign_count,
    r.ingested_at,
    coalesce(b.bid_count, 0)          as bid_count,
    b.winning_auction_score,
    i.winning_campaign_id,
    i.winning_creative_id,
    i.impression_id,
    b.request_id is not null          as is_contested_auction,
    i.impression_id is not null       as is_filled,
    -- An auction with bids that produced no impression is a render failure: we sold
    -- the inventory and then failed to show the ad. Tracked separately from "no
    -- eligible campaign", because the two have completely different owners -- one is
    -- a demand problem, the other is a client bug.
    (b.request_id is not null and i.impression_id is null) as is_render_failure
from requests r
left join bids b on r.request_id = b.request_id
left join impressions i on r.request_id = i.request_id
