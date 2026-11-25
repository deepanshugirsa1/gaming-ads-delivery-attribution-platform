-- The shape of the auction each day, by advertiser tier.
--
-- When an auction opens to self-serve buyers, the question that decides whether the
-- marketplace is healthy is whether small advertisers can win anything. If
-- self-serve win rates collapse while managed ones hold, the auction is not a
-- marketplace -- it is a queue with extra steps, and the self-serve product will
-- churn its advertisers before anyone reads a revenue report.
--
-- Reserved inventory is reported separately rather than mixed in. A reservation
-- takes its slot ahead of the auction instead of clearing it, so counting those
-- wins inside the auction win rate would make the auction look more competitive
-- than it is.

with bids as (
    select
        b.requested_date,
        b.request_id,
        b.campaign_id,
        b.bid_cpm_usd,
        b.predicted_ctr,
        b.is_winner,
        b.auction_bid_count,
        c.advertiser_id,
        c.buying_model,
        a.advertiser_tier
    from {{ ref('fct_ad_auction_bids') }} b
    left join {{ ref('dim_campaigns') }} c on b.campaign_id = c.campaign_id
    left join {{ ref('dim_advertisers') }} a on c.advertiser_id = a.advertiser_id
)

select
    requested_date,
    advertiser_tier,
    buying_model,

    count(*)                                            as bids_submitted,
    count(distinct request_id)                          as auctions_entered,
    count(distinct campaign_id)                         as campaigns_bidding,
    count(distinct advertiser_id)                       as advertisers_bidding,
    sum(case when is_winner then 1 else 0 end)          as auctions_won,

    {{ safe_div('sum(case when is_winner then 1 else 0 end)', 'count(*)') }} as win_rate,

    avg(bid_cpm_usd)                                    as avg_bid_cpm_usd,
    {{ pctl('bid_cpm_usd', 0.50) }}                     as p50_bid_cpm_usd,
    {{ pctl('bid_cpm_usd', 0.90) }}                     as p90_bid_cpm_usd,
    avg(predicted_ctr)                                  as avg_predicted_ctr,

    -- How crowded the auctions this tier competes in are. A rising number with a
    -- falling win rate is the signature of a tier being squeezed out.
    avg(auction_bid_count)                              as avg_competing_bids
from bids
group by 1, 2, 3
