-- Reserved inventory is sold directly, so where a reservation campaign entered an
-- auction it must take the slot. A reservation that lost means guaranteed delivery
-- was not delivered, which is a contractual problem rather than a reporting one.
with per_request as (
    select
        b.request_id,
        max(case when c.buying_model = 'reservation' then 1 else 0 end) as had_reservation,
        max(case when b.is_winner and c.buying_model = 'reservation' then 1 else 0 end)
            as reservation_won
    from {{ ref('fct_ad_auction_bids') }} b
    join {{ ref('dim_campaigns') }} c on b.campaign_id = c.campaign_id
    group by 1
)
select request_id, had_reservation, reservation_won
from per_request
where had_reservation = 1 and reservation_won = 0
