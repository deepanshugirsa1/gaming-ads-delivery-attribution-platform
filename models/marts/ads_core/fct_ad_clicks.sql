{{ config(
    materialized = 'incremental',
    unique_key = 'click_id',
    incremental_strategy = 'merge' if target.type == 'bigquery' else 'delete+insert',
    partition_by = {'field': 'clicked_date', 'data_type': 'date'} if target.type == 'bigquery' else none,
    cluster_by = ['campaign_id'] if target.type == 'bigquery' else none
) }}

-- One row per click, orphans included and flagged.
--
-- Orphans are kept so the rate stays reportable; every delivery metric filters them
-- out explicitly rather than losing them in a join. The distinction matters: "we
-- received 400 clicks we cannot attribute" is an incident, while a silently lower
-- click count is just a number nobody questions.

with clicks as (
    select * from {{ ref('int_ads_clicks_validated') }}

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
)

select
    k.click_id,
    k.impression_id,
    k.campaign_id,
    c.advertiser_id,
    c.objective,
    c.bid_strategy,
    k.creative_id,
    k.user_id,
    k.server_id,
    k.placement,
    k.clicked_at,
    k.clicked_date,
    k.clicked_hour,
    k.impressed_at,
    k.seconds_to_click,
    k.billable_amount_usd as click_spend_usd,
    k.is_orphan,
    k.ingested_at
from clicks k
left join campaigns c on k.campaign_id = c.campaign_id
