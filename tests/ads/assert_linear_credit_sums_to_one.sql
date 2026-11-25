-- Multi-touch credit for a single conversion must total exactly one. If it sums to
-- more, the campaign-level conversion totals are inflated -- and because each row
-- looks individually reasonable, the error shows up only as a total that nobody can
-- reconcile against the conversion count.
-- Compared with a small epsilon because the credits are fractions.
select
    conversion_id,
    sum(linear_credit) as total_credit
from {{ ref('int_ads_attribution_ranked') }}
group by 1
having abs(sum(linear_credit) - 1.0) > 0.000001
