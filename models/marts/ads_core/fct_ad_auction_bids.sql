{{ config(
    materialized = 'incremental',
    unique_key = 'bid_id',
    incremental_strategy = 'merge' if target.type == 'bigquery' else 'delete+insert',
    partition_by = {'field': 'requested_date', 'data_type': 'date'} if target.type == 'bigquery' else none,
    cluster_by = ['campaign_id'] if target.type == 'bigquery' else none
) }}

-- One row per bid: every campaign that competed for every request.
--
-- The largest table in the project and the one the ranking features are built at,
-- because ranking is a decision about candidates, not about winners. Training only
-- on impressions that served would restrict the model to ads the current ranker
-- already liked, and it would never learn that something it keeps rejecting would
-- have performed well.

with bids as (
    select * from {{ ref('stg_ads_auction_bids') }}

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

requests as (
    select
        request_id,
        requested_at,
        requested_date,
        requested_hour,
        user_id,
        server_id,
        placement,
        device_platform,
        country
    from {{ ref('stg_ads_requests') }}
),

auction_size as (
    select request_id, count(*) as auction_bid_count
    from {{ ref('stg_ads_auction_bids') }}
    group by 1
),

served as (
    select request_id, campaign_id, impression_id
    from {{ ref('int_ads_impressions_deduped') }}
)

select
    b.bid_id,
    b.request_id,
    b.campaign_id,
    b.creative_id,
    r.requested_at,
    r.requested_date,
    r.requested_hour,
    r.user_id,
    r.server_id,
    r.placement,
    r.device_platform,
    r.country,
    b.bid_cpm_usd,
    b.predicted_ctr,
    b.auction_score,
    b.is_winner,
    a.auction_bid_count,
    s.impression_id,
    -- Won the auction but never rendered. Keeping this separate from is_winner is
    -- what makes render failure measurable per campaign rather than a mystery gap
    -- between auctions won and impressions delivered.
    (b.is_winner and s.impression_id is null) as is_won_not_served,
    b.ingested_at
from bids b
left join requests r on b.request_id = r.request_id
left join auction_size a on b.request_id = a.request_id
left join served s
    on  b.request_id = s.request_id
    and b.campaign_id = s.campaign_id
