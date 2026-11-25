-- Campaign performance at (campaign, day) grain: the auction funnel, spend, and
-- attributed outcomes in one row.
--
-- The one decision that matters most in this table: conversions are counted on the
-- date of the TOUCHPOINT, not the date of the conversion.
--
-- Spend happens when the ad is served. If a click on Monday converts on Thursday
-- and we book the conversion on Thursday, then Monday shows cost with no return and
-- Thursday shows return with no cost, and every efficiency metric -- CPA, ROAS --
-- is wrong on both days. Aligning the conversion to the touchpoint that earned it
-- puts cause and effect on the same row.
--
-- The cost is that recent days are incomplete: a campaign-day's conversion count
-- keeps rising until its attribution window closes. That is a real property of
-- attributed reporting rather than a bug, so the table states it directly --
-- is_window_closed says whether a row is final, and conversions_occurred_on_date
-- keeps the conversion-dated view available for anyone who needs it.

with auctions as (
    select
        campaign_id,
        requested_date                                   as activity_date,
        count(*)                                         as auction_bids_entered,
        sum(case when is_winner then 1 else 0 end)       as auctions_won,
        sum(case when is_won_not_served then 1 else 0 end) as won_not_served,
        avg(predicted_ctr)                               as avg_predicted_ctr,
        avg(bid_cpm_usd)                                 as avg_bid_cpm_usd
    from {{ ref('fct_ad_auction_bids') }}
    group by 1, 2
),

delivery as (
    select
        campaign_id,
        impressed_date                 as activity_date,
        sum(impressions)               as impressions,
        sum(viewable_impressions)      as viewable_impressions,
        sum(clicks)                    as clicks,
        sum(total_spend_usd)           as total_spend_usd
    from {{ ref('agg_ad_delivery_daily') }}
    group by 1, 2
),

-- attributed to the day of the touchpoint that earned the credit
attributed_by_touchpoint as (
    select
        attributed_campaign_id                as campaign_id,
        cast(attributed_touchpoint_at as date) as activity_date,
        count(*)                              as attributed_conversions,
        sum(conversion_value_usd)             as attributed_conversion_value_usd,
        sum(case when attribution_type = 'click' then 1 else 0 end) as click_through_conversions,
        sum(case when attribution_type = 'view' then 1 else 0 end)  as view_through_conversions,
        avg(days_from_touchpoint_to_conversion) as avg_days_to_conversion
    from {{ ref('fct_attributed_conversions') }}
    where is_attributed
    group by 1, 2
),

-- the same conversions counted on the day they actually happened
occurred_by_date as (
    select
        attributed_campaign_id as campaign_id,
        converted_date         as activity_date,
        count(*)               as conversions_occurred_on_date
    from {{ ref('fct_attributed_conversions') }}
    where is_attributed
    group by 1, 2
),

spine as (
    select campaign_id, activity_date from auctions
    union
    select campaign_id, activity_date from delivery
    union
    select campaign_id, activity_date from attributed_by_touchpoint
),

reference as (
    -- The dataset is static, so "today" is the latest event the pipeline has seen
    -- rather than wall-clock time. Measuring completeness against the clock would
    -- mark every row stale forever.
    select max(impressed_date) as pipeline_as_of_date
    from {{ ref('fct_ad_impressions') }}
)

select
    s.activity_date,
    s.campaign_id,
    c.campaign_name,
    c.advertiser_id,
    c.vertical,
    c.objective,
    c.bid_strategy,

    coalesce(a.auction_bids_entered, 0)   as auction_bids_entered,
    coalesce(a.auctions_won, 0)           as auctions_won,
    coalesce(a.won_not_served, 0)         as won_not_served,
    a.avg_predicted_ctr,
    a.avg_bid_cpm_usd,

    coalesce(d.impressions, 0)            as impressions,
    coalesce(d.viewable_impressions, 0)   as viewable_impressions,
    coalesce(d.clicks, 0)                 as clicks,
    coalesce(d.total_spend_usd, 0)        as total_spend_usd,

    coalesce(t.attributed_conversions, 0)          as attributed_conversions,
    coalesce(t.attributed_conversion_value_usd, 0) as attributed_conversion_value_usd,
    coalesce(t.click_through_conversions, 0)       as click_through_conversions,
    coalesce(t.view_through_conversions, 0)        as view_through_conversions,
    t.avg_days_to_conversion,
    coalesce(o.conversions_occurred_on_date, 0)    as conversions_occurred_on_date,

    {{ safe_div('a.auctions_won', 'a.auction_bids_entered') }} as auction_win_rate,
    {{ safe_div('d.clicks', 'd.impressions') }}                as ctr,
    {{ safe_div('t.attributed_conversions', 'd.clicks') }}      as click_to_conversion_rate,
    {{ safe_div('t.attributed_conversions', 'd.impressions') }} as impression_to_conversion_rate,
    {{ safe_div('d.total_spend_usd', 't.attributed_conversions') }} as cost_per_acquisition_usd,
    {{ safe_div('t.attributed_conversion_value_usd', 'd.total_spend_usd') }} as return_on_ad_spend,

    r.pipeline_as_of_date,
    -- A row is final only once the widest attribution window has elapsed. Reading a
    -- CPA off a row where this is false means reading a number that is still moving.
    s.activity_date <= {{ dbt.dateadd('day', '-' ~ var('click_window_days'), 'r.pipeline_as_of_date') }}
        as is_window_closed
from spine s
cross join reference r
left join {{ ref('dim_campaigns') }} c on s.campaign_id = c.campaign_id
left join auctions a on s.campaign_id = a.campaign_id and s.activity_date = a.activity_date
left join delivery d on s.campaign_id = d.campaign_id and s.activity_date = d.activity_date
left join attributed_by_touchpoint t on s.campaign_id = t.campaign_id and s.activity_date = t.activity_date
left join occurred_by_date o on s.campaign_id = o.campaign_id and s.activity_date = o.activity_date
