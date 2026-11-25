-- Daily spend against daily budget, per campaign.
--
-- Pacing is the first thing a self-serve advertiser complains about and the first
-- thing that breaks when an auction opens to many small buyers at once: budgets are
-- small, a single popular placement can exhaust one before noon, and the advertiser
-- sees their campaign go dark without explanation.
--
-- Reservation campaigns are included but flagged, not excluded. They are not paced
-- against a daily budget at all -- the inventory is already bought -- so mixing them
-- into a pacing average would understate how aggressively the auction campaigns are
-- actually spending.

with spend as (
    select
        campaign_id,
        impressed_date as activity_date,
        sum(total_spend_usd) as spend_usd,
        sum(impressions)     as impressions
    from {{ ref('agg_ad_delivery_daily') }}
    group by 1, 2
),

campaigns as (
    select
        campaign_id,
        campaign_name,
        advertiser_id,
        buying_model,
        daily_budget_usd,
        starts_date,
        ends_date
    from {{ ref('dim_campaigns') }}
)

select
    s.activity_date,
    s.campaign_id,
    c.campaign_name,
    c.advertiser_id,
    c.buying_model,
    c.daily_budget_usd,
    s.spend_usd,
    s.impressions,

    {{ safe_div('s.spend_usd', 'c.daily_budget_usd') }} as budget_utilization,
    c.daily_budget_usd - s.spend_usd                    as unspent_budget_usd,

    c.buying_model = 'reservation'                      as is_reservation,

    -- Thresholds are deliberately wide. A campaign spending between 80% and 105% of
    -- budget is working as intended; flagging anything off exactly 100% would mark
    -- almost every campaign every day and the signal would be discarded.
    (c.buying_model <> 'reservation'
     and {{ safe_div('s.spend_usd', 'c.daily_budget_usd') }} > 1.05) as is_overspending,
    (c.buying_model <> 'reservation'
     and s.activity_date between c.starts_date and c.ends_date
     and {{ safe_div('s.spend_usd', 'c.daily_budget_usd') }} < 0.80) as is_underdelivering
from spend s
left join campaigns c on s.campaign_id = c.campaign_id
