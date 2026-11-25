-- One row per creative, with lifetime delivery performance.
--
-- Creative-level CTR is the number creative teams ask for, so it is defined once
-- here rather than recomputed per dashboard. Orphan clicks are excluded: a click
-- whose impression never arrived cannot be credited to a creative, and including
-- it would produce a CTR above what the impressions can support.

with creatives as (
    select * from {{ ref('stg_ads_creatives') }}
),

delivery as (
    select
        i.creative_id,
        count(*)                                            as impressions,
        sum(case when i.is_viewable then 1 else 0 end)       as viewable_impressions,
        count(c.click_id)                                   as clicks,
        sum(i.billable_amount_usd)                          as impression_spend_usd,
        min(i.impressed_at)                                 as first_impressed_at,
        max(i.impressed_at)                                 as last_impressed_at
    from {{ ref('int_ads_impressions_deduped') }} i
    left join {{ ref('int_ads_clicks_validated') }} c
        on  i.impression_id = c.impression_id
        and not c.is_orphan
    group by 1
)

select
    cr.creative_id,
    cr.campaign_id,
    cr.creative_format,
    cr.duration_sec,
    cr.created_at,
    coalesce(d.impressions, 0)           as impressions,
    coalesce(d.viewable_impressions, 0)  as viewable_impressions,
    coalesce(d.clicks, 0)                as clicks,
    coalesce(d.impression_spend_usd, 0)  as impression_spend_usd,
    d.first_impressed_at,
    d.last_impressed_at,
    {{ safe_div('d.clicks', 'd.impressions') }}            as lifetime_ctr,
    {{ safe_div('d.viewable_impressions', 'd.impressions') }} as lifetime_viewable_rate
from creatives cr
left join delivery d on cr.creative_id = d.creative_id
