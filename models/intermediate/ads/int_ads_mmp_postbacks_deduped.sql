-- One row per postback_id, keeping the first receipt.
--
-- Measurement partners retransmit. Two deliveries of the same postback_id are one
-- conversion claimed twice, and counting both would inflate third-party totals and
-- then show up as a parity gap against first-party -- a data-quality artefact
-- masquerading as a measurement discrepancy, which is the most expensive kind of
-- bug to chase because it looks like a real business finding.

with ranked as (
    select
        *,
        row_number() over (
            partition by postback_id
            order by received_at asc
        ) as receipt_sequence
    from {{ ref('stg_ads_mmp_postbacks') }}
)

select
    postback_id,
    mmp_name,
    feed_contract,
    advertiser_id,
    claimed_campaign_id,
    claimed_user_id,
    claimed_device_id,
    event_name,
    event_at,
    event_date,
    received_at,
    claimed_attribution_type,
    claimed_value_usd,
    receive_lag_minutes,
    is_unidentified_user
from ranked
where receipt_sequence = 1
