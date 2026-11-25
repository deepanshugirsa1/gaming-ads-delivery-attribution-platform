-- One row per placement, with the funnel from request to click.
--
-- Small table, high traffic: it is the first thing anyone opens when asked which
-- surfaces are worth more inventory. Rates are defined once here so a product
-- question about placement value does not get three different answers.

with requests as (
    select
        placement,
        count(*)                                        as ad_requests,
        sum(case when is_contested_auction then 1 else 0 end) as contested_auctions,
        sum(case when is_filled then 1 else 0 end)      as filled_requests,
        sum(case when is_render_failure then 1 else 0 end) as render_failures,
        count(distinct user_id)                         as reached_users
    from {{ ref('fct_ad_requests') }}
    group by 1
),

delivery as (
    select
        placement,
        count(*)                                          as impressions,
        sum(case when is_viewable then 1 else 0 end)       as viewable_impressions,
        sum(case when is_clicked then 1 else 0 end)        as clicks,
        sum(total_spend_usd)                               as spend_usd,
        avg(view_duration_ms)                              as avg_view_duration_ms
    from {{ ref('fct_ad_impressions') }}
    group by 1
)

select
    r.placement,
    r.ad_requests,
    r.contested_auctions,
    r.filled_requests,
    r.render_failures,
    r.reached_users,
    coalesce(d.impressions, 0)          as impressions,
    coalesce(d.viewable_impressions, 0) as viewable_impressions,
    coalesce(d.clicks, 0)               as clicks,
    coalesce(d.spend_usd, 0)            as spend_usd,
    d.avg_view_duration_ms,
    {{ safe_div('r.contested_auctions', 'r.ad_requests') }}   as auction_contest_rate,
    {{ safe_div('r.filled_requests', 'r.ad_requests') }}      as fill_rate,
    {{ safe_div('r.render_failures', 'r.contested_auctions') }} as render_failure_rate,
    {{ safe_div('d.clicks', 'd.impressions') }}               as ctr,
    {{ safe_div('d.viewable_impressions', 'd.impressions') }} as viewable_rate,
    {{ safe_div('d.spend_usd * 1000', 'd.impressions') }}     as effective_cpm_usd
from requests r
left join delivery d on r.placement = d.placement
