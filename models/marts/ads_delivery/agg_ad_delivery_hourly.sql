{{ config(
    materialized = 'incremental',
    unique_key = ['campaign_id', 'creative_id', 'placement', 'impressed_hour'],
    incremental_strategy = 'merge' if target.type == 'bigquery' else 'delete+insert',
    partition_by = {'field': 'impressed_date', 'data_type': 'date'} if target.type == 'bigquery' else none,
    cluster_by = ['campaign_id'] if target.type == 'bigquery' else none
) }}

-- Delivery at hourly grain: the lowest-latency reporting surface in the project.
--
-- Deliberately thin. This table carries delivery and spend only -- no attributed
-- conversions, no ML features -- because its job is to be current, and a conversion
-- cannot be attributed until its window has had time to close. Mixing a metric that
-- is final within minutes and one that is not final for a week into a single table
-- produces a surface where half the columns silently change under the reader.
--
-- Whole hours are recomputed and merged rather than appended, so a late-arriving
-- impression corrects its hour instead of creating a second row for it.

with impressions as (
    select * from {{ ref('fct_ad_impressions') }}

    {% if is_incremental() %}
    where impressed_hour >= (
        select coalesce(
            {{ dbt.dateadd('day', '-' ~ var('incremental_lookback_days'), 'max(impressed_hour)') }},
            cast('1970-01-01' as timestamp)
        )
        from {{ this }}
    )
    {% endif %}
)

select
    campaign_id,
    creative_id,
    placement,
    impressed_hour,
    impressed_date,
    count(*)                                          as impressions,
    sum(case when is_viewable then 1 else 0 end)      as viewable_impressions,
    sum(case when is_clicked then 1 else 0 end)       as clicks,
    count(distinct user_id)                           as reached_users,
    sum(impression_spend_usd)                         as impression_spend_usd,
    sum(click_spend_usd)                              as click_spend_usd,
    sum(total_spend_usd)                              as total_spend_usd,
    {{ safe_div('sum(case when is_clicked then 1 else 0 end)', 'count(*)') }} as ctr,
    {{ safe_div('sum(case when is_viewable then 1 else 0 end)', 'count(*)') }} as viewable_rate,
    {{ safe_div('sum(total_spend_usd) * 1000', 'count(*)') }} as effective_cpm_usd,
    max(ingested_at)                                  as latest_ingested_at
from impressions
group by 1, 2, 3, 4, 5
