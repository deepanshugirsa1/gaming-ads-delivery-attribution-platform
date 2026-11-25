-- Each conversion with any in-window touchpoint must have exactly one winner.
-- Zero winners means the ranking lost the conversion; two means the tie-break is not
-- deterministic and the same data can credit two different campaigns on two runs.
select
    conversion_id,
    sum(case when is_attributed_touchpoint then 1 else 0 end) as winners
from {{ ref('int_ads_attribution_ranked') }}
group by 1
having sum(case when is_attributed_touchpoint then 1 else 0 end) <> 1
