{{ config(
    materialized = 'incremental',
    unique_key = 'conversion_id',
    incremental_strategy = 'merge' if target.type == 'bigquery' else 'delete+insert',
    partition_by = {'field': 'converted_date', 'data_type': 'date'} if target.type == 'bigquery' else none,
    cluster_by = ['advertiser_id', 'conversion_type'] if target.type == 'bigquery' else none
) }}

-- One row per first-party conversion, before attribution.
--
-- Deliberately separate from fct_attributed_conversions. This table answers "how
-- many conversions happened", which is a fact about the advertiser's business.
-- Attribution answers "which ad should get the credit", which is a modelling
-- choice with tunable windows. Conflating the two means every change to an
-- attribution window appears to change the number of conversions that occurred,
-- and that is how a measurement conversation stops being possible.

with conversions as (
    select * from {{ ref('int_ads_conversions_resolved') }}

    {% if is_incremental() %}
    where ingested_at >= (
        select coalesce(
            {{ dbt.dateadd('day', '-' ~ var('incremental_lookback_days'), 'max(ingested_at)') }},
            cast('1970-01-01' as timestamp)
        )
        from {{ this }}
    )
    {% endif %}
)

select
    conversion_id,
    user_id,
    observed_user_id,
    conversion_device_id,
    device_resolution_method,
    device_resolution_confidence,
    had_observed_identity,
    -- attributable only because the identity graph found an owner
    is_identity_recovered,
    is_unidentified,
    advertiser_id,
    conversion_type,
    converted_at,
    converted_date,
    conversion_value_usd,
    source_system,
    device_platform,
    ingested_at,
    ingest_lag_minutes,
    -- Flagged rather than filtered: a conversion that took longer to arrive than the
    -- incremental lookback is a row we would have missed, and counting them is how
    -- we know whether the lookback is still wide enough.
    ingest_lag_minutes > {{ var('incremental_lookback_days') }} * 24 * 60
        as exceeded_incremental_lookback
from conversions
