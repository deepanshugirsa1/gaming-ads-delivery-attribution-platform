-- The maturity flag must agree with the arithmetic it claims to encode: a label is
-- final only once a full click window has passed since the auction.
-- Tested because this flag is the only thing standing between the training set and
-- a week of conversions labelled "no" that simply have not happened yet.
select
    bid_id,
    requested_date,
    pipeline_as_of_date,
    is_conversion_label_mature
from {{ ref('fct_ranking_labels') }}
where is_conversion_label_mature
  and requested_date > {{ dbt.dateadd('day', '-' ~ var('label_maturity_days'), 'pipeline_as_of_date') }}
