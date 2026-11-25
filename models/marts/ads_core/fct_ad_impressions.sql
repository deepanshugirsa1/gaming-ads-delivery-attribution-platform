{{ config(
    materialized = 'incremental',
    unique_key = 'impression_id',
    incremental_strategy = 'merge' if target.type == 'bigquery' else 'delete+insert',
    partition_by = {'field': 'impressed_date', 'data_type': 'date'} if target.type == 'bigquery' else none,
    cluster_by = ['campaign_id', 'placement'] if target.type == 'bigquery' else none
) }}

-- One row per delivered impression, deduplicated, enriched with campaign context
-- and whether it was clicked.
--
-- The canonical impression table: anything that reports delivery reads this and not
-- staging, so the deduplication rule is applied exactly once and every downstream
-- number agrees on what an impression is.

with impressions as (
    select * from {{ ref('int_ads_impressions_deduped') }}

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

campaigns as (
    select campaign_id, advertiser_id, objective, bid_strategy
    from {{ ref('stg_ads_campaigns') }}
),

creatives as (
    select creative_id, creative_format
    from {{ ref('stg_ads_creatives') }}
),

clicks as (
    select impression_id, click_id, clicked_at, billable_amount_usd as click_spend_usd
    from {{ ref('int_ads_clicks_validated') }}
    where not is_orphan
)

select
    i.impression_id,
    i.request_id,
    i.campaign_id,
    c.advertiser_id,
    c.objective,
    c.bid_strategy,
    i.creative_id,
    cr.creative_format,
    i.user_id,
    i.server_id,
    i.placement,
    i.impressed_at,
    i.impressed_date,
    i.impressed_hour,
    i.billable_amount_usd       as impression_spend_usd,
    coalesce(k.click_spend_usd, 0) as click_spend_usd,
    -- Total spend sits on the impression because a CPM campaign bills on delivery
    -- and a CPC campaign bills on the click. Spend therefore comes from two tables,
    -- and summing only one of them understates every CPC campaign's cost -- which
    -- is exactly the kind of error that makes a ROAS number quietly wrong.
    i.billable_amount_usd + coalesce(k.click_spend_usd, 0) as total_spend_usd,
    i.is_viewable,
    i.view_duration_ms,
    k.click_id is not null      as is_clicked,
    k.clicked_at,
    i.ingested_at
from impressions i
left join campaigns c on i.campaign_id = c.campaign_id
left join creatives cr on i.creative_id = cr.creative_id
left join clicks k on i.impression_id = k.impression_id
