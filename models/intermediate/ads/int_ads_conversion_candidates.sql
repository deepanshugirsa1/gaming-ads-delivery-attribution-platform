-- Every (conversion, touchpoint) pair that could plausibly be credited, collected
-- at the widest window the project ever reports on.
--
-- Design decision worth stating plainly: candidates are gathered at
-- max_click_window_days / max_view_window_days (28 and 7), not at the configured
-- reporting windows (7 and 1). Narrower windows are then a filter over this table.
-- That means changing the reported window, or answering "what would our numbers
-- look like on a 14-day window", is a query rather than a full reprocess -- and
-- measurement debates get settled with numbers the same afternoon.
--
-- Matching is on user and advertiser, not campaign. A conversion is an event at the
-- advertiser; which of their campaigns earns the credit is precisely the question
-- attribution answers, so campaign cannot be part of the join key.
--
-- A clicked impression contributes its click and not also a view. Letting both
-- through would double-count the same exposure and hand view-through credit to
-- impressions that already earned click credit.

{% set max_click = var('max_click_window_days') %}
{% set max_view = var('max_view_window_days') %}

with impressions as (
    select
        i.impression_id,
        i.campaign_id,
        c.advertiser_id,
        i.user_id,
        i.impressed_at,
        i.creative_id,
        i.placement
    from {{ ref('int_ads_impressions_deduped') }} i
    join {{ ref('stg_ads_campaigns') }} c
        on i.campaign_id = c.campaign_id
),

clicks as (
    select
        k.click_id,
        k.impression_id,
        i.campaign_id,
        i.advertiser_id,
        k.user_id,
        k.clicked_at,
        i.creative_id,
        i.placement
    from {{ ref('int_ads_clicks_validated') }} k
    join impressions i
        on k.impression_id = i.impression_id
    where not k.is_orphan
),

touchpoints as (
    select
        'click'       as touchpoint_type,
        click_id      as touchpoint_id,
        impression_id,
        campaign_id,
        advertiser_id,
        user_id,
        creative_id,
        placement,
        clicked_at    as touchpoint_at
    from clicks

    union all

    select
        'view'            as touchpoint_type,
        i.impression_id   as touchpoint_id,
        i.impression_id,
        i.campaign_id,
        i.advertiser_id,
        i.user_id,
        i.creative_id,
        i.placement,
        i.impressed_at    as touchpoint_at
    from impressions i
    left join clicks k
        on i.impression_id = k.impression_id
    where k.click_id is null
),

conversions as (
    select * from {{ ref('stg_ads_conversions') }}
)

select
    cv.conversion_id,
    cv.user_id,
    cv.advertiser_id,
    cv.conversion_type,
    cv.converted_at,
    cv.converted_date,
    cv.conversion_value_usd,
    tp.touchpoint_type,
    tp.touchpoint_id,
    tp.impression_id,
    tp.campaign_id,
    tp.creative_id,
    tp.placement,
    tp.touchpoint_at,
    -- Fractional days, from seconds. Using datediff in hours or days would truncate,
    -- and a conversion 7.4 days after a click would land inside a 7-day window.
    {{ dbt.datediff('tp.touchpoint_at', 'cv.converted_at', 'second') }} / 86400.0
        as days_to_conversion
from conversions cv
join touchpoints tp
    on  tp.user_id = cv.user_id
    and tp.advertiser_id = cv.advertiser_id
    and tp.touchpoint_at <= cv.converted_at
    and tp.touchpoint_at >= case
            when tp.touchpoint_type = 'click'
                then {{ dbt.dateadd('day', -max_click, 'cv.converted_at') }}
            else {{ dbt.dateadd('day', -max_view, 'cv.converted_at') }}
        end
