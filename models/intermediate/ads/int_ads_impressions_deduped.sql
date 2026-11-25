-- One row per impression_id, keeping the first delivery.
--
-- The collector retransmits a small share of impressions with the same
-- impression_id and a later ingest timestamp. The first delivery is the event;
-- everything after it is the pipeline talking to itself. Counting both would
-- inflate impressions, deflate CTR, and overstate spend -- and because the
-- duplicate rate is small, it would do so invisibly.
--
-- The duplicate count is deliberately kept as a measurable quantity rather than
-- just filtered: stg_ads_impressions holds the raw rows, this model holds the
-- deduplicated ones, and mart_ads_pipeline_health reports the gap between them so
-- a sudden jump in retransmissions is visible instead of merely absorbed.

with ranked as (
    select
        *,
        row_number() over (
            partition by impression_id
            order by ingested_at asc
        ) as delivery_sequence
    from {{ ref('stg_ads_impressions') }}
)

select
    impression_id,
    request_id,
    campaign_id,
    creative_id,
    user_id,
    server_id,
    placement,
    impressed_at,
    impressed_date,
    impressed_hour,
    billable_amount_usd,
    is_viewable,
    view_duration_ms,
    ingested_at
from ranked
where delivery_sequence = 1
