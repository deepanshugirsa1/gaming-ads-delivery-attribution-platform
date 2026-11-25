-- One row per deduplicated third-party postback, with every assertion the partner
-- made checked against what we actually know.
--
-- The matching rule tolerates a minute of clock skew rather than demanding an exact
-- timestamp. Two systems recording the same event will not agree to the second, and
-- an exact-match join would classify ordinary skew as "the partner reported a
-- conversion we have no record of" -- turning a clock problem into a fake
-- measurement discrepancy.
--
-- Where several first-party conversions fall inside the tolerance, the nearest in
-- time wins, deterministically, so the match is reproducible.

with resolved_devices as (
    select device_id, resolved_user_id, resolution_method
    from {{ ref('int_identity_resolved_devices') }}
),

postbacks as (
    -- A partner that cannot pass a user identifier can still pass a device. Resolving
    -- it recovers postbacks that would otherwise sit in the unattributable bucket and
    -- show up as a parity gap we could not explain.
    select
        p.*,
        coalesce(p.claimed_user_id, rd.resolved_user_id) as resolved_claimed_user_id,
        (p.claimed_user_id is null and rd.resolved_user_id is not null)
            as is_identity_recovered,
        rd.resolution_method as device_resolution_method
    from {{ ref('int_ads_mmp_postbacks_deduped') }} p
    left join resolved_devices rd on p.claimed_device_id = rd.device_id
),

conversions as (
    select
        conversion_id,
        user_id,
        advertiser_id,
        conversion_type,
        converted_at,
        conversion_value_usd
    from {{ ref('fct_conversions') }}
),

campaigns as (
    select campaign_id, advertiser_id as campaign_advertiser_id, campaign_name
    from {{ ref('stg_ads_campaigns') }}
),

matched as (
    select
        p.postback_id,
        cv.conversion_id,
        cv.conversion_value_usd                                   as first_party_value_usd,
        abs({{ dbt.datediff('p.event_at', 'cv.converted_at', 'second') }}) as match_skew_seconds,
        row_number() over (
            partition by p.postback_id
            order by abs({{ dbt.datediff('p.event_at', 'cv.converted_at', 'second') }}) asc,
                     cv.conversion_id asc
        ) as match_rank
    from postbacks p
    join conversions cv
        on  p.resolved_claimed_user_id = cv.user_id
        and p.advertiser_id = cv.advertiser_id
        and p.event_name = cv.conversion_type
        and abs({{ dbt.datediff('p.event_at', 'cv.converted_at', 'second') }}) <= 60
),

best_match as (
    select postback_id, conversion_id, first_party_value_usd, match_skew_seconds
    from matched
    where match_rank = 1
)

select
    p.postback_id,
    p.mmp_name,
    p.feed_contract,
    p.advertiser_id,
    p.claimed_campaign_id,
    p.claimed_user_id,
    p.claimed_device_id,
    p.resolved_claimed_user_id,
    p.is_identity_recovered,
    p.device_resolution_method,
    p.event_name,
    p.event_at,
    p.event_date,
    p.received_at,
    p.receive_lag_minutes,
    p.claimed_attribution_type,
    p.claimed_value_usd,
    p.resolved_claimed_user_id is null as is_unidentified_user,

    c.campaign_id is not null                     as claimed_campaign_exists,
    c.campaign_advertiser_id,
    -- The partner claims both an advertiser and a campaign. If the campaign belongs
    -- to a different advertiser, the postback is internally inconsistent and must not
    -- be trusted for billing, however plausible the rest of it looks.
    (c.campaign_id is not null and c.campaign_advertiser_id <> p.advertiser_id)
        as has_advertiser_mismatch,

    m.conversion_id                               as matched_conversion_id,
    m.first_party_value_usd,
    m.match_skew_seconds,
    m.conversion_id is not null                   as has_first_party_match,
    -- No first-party record at all. Either our SDK missed it or the partner is
    -- over-claiming; either way it is the number that explains a parity gap.
    (m.conversion_id is null and not p.is_unidentified_user) as is_third_party_only,
    case
        when m.conversion_id is not null and m.first_party_value_usd <> p.claimed_value_usd
        then p.claimed_value_usd - m.first_party_value_usd
    end as value_discrepancy_usd
from postbacks p
left join campaigns c on p.claimed_campaign_id = c.campaign_id
left join best_match m on p.postback_id = m.postback_id
