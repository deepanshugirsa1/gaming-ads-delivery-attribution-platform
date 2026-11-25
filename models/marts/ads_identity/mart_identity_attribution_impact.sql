-- What the identity graph is actually worth, in conversions.
--
-- The table to open when someone asks whether identity resolution earns its
-- complexity. It answers in the only terms that matter: how many conversions would
-- have been unattributable without it, and what they were worth.
--
-- attribution_coverage_without_graph is computed by removing exactly the conversions
-- that were attributed *only* because the graph resolved their device. That is a
-- counterfactual, not a measurement — a conversion attributed through a recovered
-- identity might have been attributed anyway had the identifier been present. It is
-- an upper bound on the graph's contribution, and it is labelled as one.

with attributed as (
    select * from {{ ref('fct_attributed_conversions') }}
)

select
    converted_date,

    count(*)                                                        as conversions,
    sum(case when had_observed_identity then 1 else 0 end)          as with_observed_identity,
    sum(case when is_identity_recovered then 1 else 0 end)          as identity_recovered_by_graph,
    sum(case when not had_observed_identity and not is_identity_recovered then 1 else 0 end)
                                                                    as still_unidentified,

    sum(case when is_attributed then 1 else 0 end)                  as attributed_conversions,
    sum(case when is_attributed and is_identity_recovered then 1 else 0 end)
                                                                    as attributed_only_via_graph,
    sum(case when is_attributed and is_identity_recovered
             then conversion_value_usd else 0 end)                  as value_recovered_usd,
    sum(case when is_attributed and device_resolution_method = 'probabilistic'
             then 1 else 0 end)                                     as attributed_via_probabilistic,

    {{ safe_div('sum(case when is_attributed then 1 else 0 end)', 'count(*)') }}
        as attribution_coverage,
    {{ safe_div(
        'sum(case when is_attributed then 1 else 0 end) - sum(case when is_attributed and is_identity_recovered then 1 else 0 end)',
        'count(*)'
    ) }} as attribution_coverage_without_graph,
    {{ safe_div('sum(case when is_identity_recovered then 1 else 0 end)',
                'sum(case when not had_observed_identity then 1 else 0 end)') }}
        as recovery_rate_of_unidentified
from attributed
group by 1
