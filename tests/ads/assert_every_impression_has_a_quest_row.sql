-- fct_quest_completions must cover every impression exactly once. If it covers
-- fewer, completion rates are computed against a denominator that quietly excludes
-- the impressions that produced nothing — which is precisely the population that
-- makes a rewarded format look worse than the averages suggest.
with impressions as (
    select count(*) as n from {{ ref('fct_ad_impressions') }}
),
completions as (
    select count(*) as n from {{ ref('fct_quest_completions') }}
)
select i.n as impressions, c.n as quest_rows
from impressions i
cross join completions c
where i.n <> c.n
