-- One row per ingested feed: volume, duplication, arrival lag, and whether the feed
-- is inside its SLA.
--
-- The operational table. When a number looks wrong, this is the first place to look,
-- because it answers the question that explains most wrong numbers: did all the data
-- arrive, and did any of it arrive twice.
--
-- Lag is measured against the latest ingest among feeds with an equal or tighter
-- SLA, not against the clock and not against the single latest row in the pipeline.
-- A wall-clock check marks a historical extract stale forever. Using the global
-- maximum does the same thing in the other direction: conversions are allowed to
-- land days after the click, and that one late row would mark every real-time feed
-- as hours behind. A click feed is late when it falls behind the other click-speed
-- feeds, not when a conversion feed is still inside its own multi-day contract.
--
-- The SLA per feed comes from source_freshness_registry in dbt_project.yml, so adding
-- a feed or renegotiating a threshold is a config change with a visible diff rather
-- than an edit buried in SQL.

{% set registry = var('source_freshness_registry') %}

with feeds as (
    {% for entry in registry %}
    select
        '{{ entry["table"] }}'                       as feed_name,
        count(*)                                     as rows_received,
        count(distinct {{ entry["key"] }})           as distinct_keys,
        max({{ entry["event_at"] }})                 as latest_event_at,
        max(ingested_at)                             as latest_ingested_at,
        {{ entry["sla_minutes"] }}                   as sla_minutes
    from {{ ref(entry["table"]) }}
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
),

reference as (
    -- Peer reference: the newest ingest among feeds this one is expected to keep
    -- up with. A looser SLA cannot set the clock for a tighter one.
    select
        f.feed_name,
        max(o.latest_ingested_at) as pipeline_latest_ingested_at
    from feeds f
    join feeds o
        on o.sla_minutes <= f.sla_minutes
    group by 1
),

orphan_clicks as (
    select
        count(*)                                        as total_clicks,
        sum(case when is_orphan then 1 else 0 end)      as orphan_clicks
    from {{ ref('fct_ad_clicks') }}
),

late_conversions as (
    select
        count(*)                                                        as total_conversions,
        sum(case when exceeded_incremental_lookback then 1 else 0 end)  as beyond_lookback,
        max(ingest_lag_minutes)                                         as max_ingest_lag_minutes,
        {{ pctl('ingest_lag_minutes', 0.95) }}                          as p95_ingest_lag_minutes
    from {{ ref('fct_conversions') }}
)

select
    f.feed_name,
    f.rows_received,
    f.distinct_keys,
    f.rows_received - f.distinct_keys                       as duplicate_rows,
    {{ safe_div('f.rows_received - f.distinct_keys', 'f.rows_received') }} as duplicate_rate,
    f.latest_event_at,
    f.latest_ingested_at,
    r.pipeline_latest_ingested_at,
    {{ dbt.datediff('f.latest_ingested_at', 'r.pipeline_latest_ingested_at', 'minute') }}
        as minutes_behind_pipeline,
    f.sla_minutes,
    {{ dbt.datediff('f.latest_ingested_at', 'r.pipeline_latest_ingested_at', 'minute') }}
        <= f.sla_minutes as is_within_sla,

    -- Pipeline-wide counters, repeated on each row so a single query answers "is
    -- anything wrong right now" without three more joins.
    oc.orphan_clicks,
    {{ safe_div('oc.orphan_clicks', 'oc.total_clicks') }}   as orphan_click_rate,
    lc.beyond_lookback                                       as conversions_beyond_lookback,
    lc.max_ingest_lag_minutes                                as conversion_max_ingest_lag_minutes,
    lc.p95_ingest_lag_minutes                                as conversion_p95_ingest_lag_minutes
from feeds f
join reference r on f.feed_name = r.feed_name
cross join orphan_clicks oc
cross join late_conversions lc
