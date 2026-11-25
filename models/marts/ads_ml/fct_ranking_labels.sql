-- Outcomes for every bid, with an explicit statement of whether each label is final.
--
-- The three labels mature at completely different speeds, which is the single most
-- important fact about training a ranker on this data:
--
--   was_served   -- known within seconds of the auction
--   was_clicked  -- known within minutes
--   was_attributed_conversion -- NOT known for up to click_window_days
--
-- Treating all three as equally final is the classic way to poison a training set.
-- A bid from yesterday has a conversion label of false, but that false means
-- "not yet", not "never". Train on it and the model learns that recent impressions
-- never convert, which is both wrong and self-reinforcing, because the model then
-- stops serving the inventory that would have converted.
--
-- So is_conversion_label_mature is computed, exposed, and enforced by the training
-- set downstream -- and by a singular test, because this is exactly the kind of
-- guard someone removes to "get more training data".

with bids as (
    select
        bid_id,
        request_id,
        campaign_id,
        user_id,
        requested_at,
        requested_date,
        impression_id,
        is_winner
    from {{ ref('fct_ad_auction_bids') }}
),

impressions as (
    select impression_id, is_clicked, clicked_at
    from {{ ref('fct_ad_impressions') }}
),

conversions as (
    -- An attributed conversion belongs to the impression that earned the credit, so
    -- the label attaches to that impression's bid and to no other.
    select
        attributed_impression_id as impression_id,
        count(*)                 as attributed_conversions,
        sum(conversion_value_usd) as attributed_conversion_value_usd,
        min(converted_at)        as first_converted_at
    from {{ ref('fct_attributed_conversions') }}
    where is_attributed
      and attributed_impression_id is not null
    group by 1
),

reference as (
    select max(impressed_date) as pipeline_as_of_date
    from {{ ref('fct_ad_impressions') }}
)

select
    b.bid_id,
    b.request_id,
    b.campaign_id,
    b.user_id,
    b.requested_at,
    b.requested_date,
    b.impression_id,

    b.impression_id is not null                        as was_served,
    coalesce(i.is_clicked, false)                      as was_clicked,
    coalesce(cv.attributed_conversions, 0) > 0         as was_attributed_conversion,
    coalesce(cv.attributed_conversions, 0)             as attributed_conversions,
    coalesce(cv.attributed_conversion_value_usd, 0)    as attributed_conversion_value_usd,
    i.clicked_at,
    cv.first_converted_at,

    r.pipeline_as_of_date,
    -- The conversion label is final only once the full click window has elapsed
    -- since the auction. Until then a false label is unresolved, not negative.
    b.requested_date <= {{ dbt.dateadd('day', '-' ~ var('label_maturity_days'), 'r.pipeline_as_of_date') }}
        as is_conversion_label_mature,
    {{ dbt.dateadd('day', var('label_maturity_days'), 'b.requested_date') }}
        as conversion_label_matures_on
from bids b
cross join reference r
left join impressions i on b.impression_id = i.impression_id
left join conversions cv on b.impression_id = cv.impression_id
