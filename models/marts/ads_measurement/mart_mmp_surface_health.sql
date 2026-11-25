-- One row per measurement partner per day: how well that surface is behaving.
--
-- Parity tells you the numbers disagree. This tells you whether the disagreement is
-- the partner's pipeline rather than genuine attribution difference -- retransmission
-- rate, identifier loss, delivery lag, internally inconsistent claims. When a parity
-- breach fires, this is the table that says whether to investigate our attribution
-- or email the vendor.

with postbacks as (
    select * from {{ ref('fct_mmp_postbacks') }}
),

raw_counts as (
    -- counted before deduplication, so the retransmission rate stays observable
    select
        mmp_name,
        event_date,
        count(*)                            as postbacks_received,
        count(distinct postback_id)         as distinct_postbacks
    from {{ ref('stg_ads_mmp_postbacks') }}
    group by 1, 2
)

select
    p.event_date,
    p.mmp_name,
    p.feed_contract,
    count(*)                                                        as postbacks_deduplicated,
    r.postbacks_received,
    r.postbacks_received - r.distinct_postbacks                     as retransmitted_postbacks,
    {{ safe_div('r.postbacks_received - r.distinct_postbacks', 'r.postbacks_received') }}
        as retransmission_rate,

    sum(case when p.is_unidentified_user then 1 else 0 end)          as unidentified_user_postbacks,
    {{ safe_div('sum(case when p.is_unidentified_user then 1 else 0 end)', 'count(*)') }}
        as unidentified_user_rate,

    sum(case when p.claimed_campaign_exists then 0 else 1 end)       as unknown_campaign_claims,
    sum(case when p.has_advertiser_mismatch then 1 else 0 end)       as advertiser_mismatches,
    sum(case when p.has_first_party_match then 1 else 0 end)         as matched_to_first_party,
    sum(case when p.is_third_party_only then 1 else 0 end)           as third_party_only,
    {{ safe_div('sum(case when p.has_first_party_match then 1 else 0 end)', 'count(*)') }}
        as first_party_match_rate,

    sum(case when p.value_discrepancy_usd is not null then 1 else 0 end) as value_discrepancies,
    sum(coalesce(abs(p.value_discrepancy_usd), 0))                   as abs_value_discrepancy_usd,

    avg(p.receive_lag_minutes)                                       as avg_receive_lag_minutes,
    {{ pctl('p.receive_lag_minutes', 0.5) }}                         as p50_receive_lag_minutes,
    {{ pctl('p.receive_lag_minutes', 0.95) }}                        as p95_receive_lag_minutes,
    max(p.receive_lag_minutes)                                       as max_receive_lag_minutes
from postbacks p
left join raw_counts r
    on p.mmp_name = r.mmp_name and p.event_date = r.event_date
group by 1, 2, 3, r.postbacks_received, r.distinct_postbacks
