-- Every click, with a flag for the ones whose impression was never logged.
--
-- A click arriving for an unknown impression means the impression pipeline dropped
-- a row, the click tracker fired on a stale creative, or something is spoofing
-- clicks. All three matter. The tempting move is an inner join to impressions,
-- which makes the problem disappear from every downstream number -- clicks quietly
-- go missing, CTR quietly drops, and nothing fails.
--
-- So orphans are retained and flagged. They are excluded from attribution, because
-- a click with no impression cannot be credited to a campaign, but they stay
-- countable so the orphan rate can be monitored and alerted on.

with clicks as (
    select * from {{ ref('stg_ads_clicks') }}
),

impressions as (
    select
        impression_id,
        campaign_id,
        creative_id,
        placement,
        server_id,
        impressed_at
    from {{ ref('int_ads_impressions_deduped') }}
)

select
    c.click_id,
    c.impression_id,
    c.user_id,
    c.clicked_at,
    c.clicked_date,
    c.clicked_hour,
    c.billable_amount_usd,
    c.ingested_at,
    i.campaign_id,
    i.creative_id,
    i.placement,
    i.server_id,
    i.impressed_at,
    i.impression_id is null as is_orphan,
    -- Negative values would mean a click logged before its own impression, which is
    -- a clock-skew or ordering bug rather than user behaviour. Tested downstream.
    case
        when i.impression_id is not null
        then {{ dbt.datediff('i.impressed_at', 'c.clicked_at', 'second') }}
    end as seconds_to_click
from clicks c
left join impressions i
    on c.impression_id = i.impression_id
