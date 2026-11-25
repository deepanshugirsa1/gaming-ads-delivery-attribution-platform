-- One row per campaign, with its targeting clauses interpreted.
--
-- The source stores targeting as pipe-delimited text with the sentinel 'ALL' for
-- unrestricted. Interpreting that is business logic, so it happens exactly once,
-- here, where it is documented and tested -- rather than in every analysis that
-- needs to know whether a campaign was geo-restricted.
--
-- Item counts are derived by measuring how many delimiters a clause contains rather
-- than splitting it into an array, because array functions are spelled differently
-- on BigQuery and DuckDB and this project has to produce identical results on both.
-- The count is null, not zero, for an unrestricted clause: 'ALL' is not a list of
-- length one, and treating it as one would make "average countries targeted" wrong.

with campaigns as (
    select * from {{ ref('stg_ads_campaigns') }}
),

advertisers as (
    select advertiser_id, advertiser_name, vertical
    from {{ ref('stg_ads_advertisers') }}
),

creatives as (
    select
        campaign_id,
        count(*)                        as creative_count,
        count(distinct creative_format) as creative_format_count
    from {{ ref('stg_ads_creatives') }}
    group by 1
)

select
    c.campaign_id,
    c.campaign_name,
    c.advertiser_id,
    a.advertiser_name,
    a.vertical,
    c.objective,
    c.quest_format,
    c.buying_model,
    c.reward_orbs,
    c.completion_threshold_seconds,
    c.required_playtime_minutes,
    -- Exactly one reward rule applies per format; carrying both and naming which is
    -- live saves every downstream reader from re-deriving it from the format string.
    case
        when c.quest_format in ('video_quest', 'video_quest_reserve') then 'seconds_viewed'
        else 'playtime_minutes'
    end as reward_rule,
    c.buying_model = 'reservation' as is_reserved_inventory,
    c.bid_strategy,
    c.bid_amount_usd,
    c.daily_budget_usd,
    c.starts_at,
    c.ends_at,
    c.starts_date,
    c.ends_date,
    {{ dbt.datediff('c.starts_at', 'c.ends_at', 'day') }} as scheduled_duration_days,

    c.target_countries,
    c.target_platforms,
    c.target_server_categories,
    c.target_countries = 'ALL'          as targets_all_countries,
    c.target_platforms = 'all'          as targets_all_platforms,
    c.target_server_categories = 'all'  as targets_all_server_categories,

    case when c.target_countries <> 'ALL'
         then length(c.target_countries) - length(replace(c.target_countries, '|', '')) + 1
    end as target_country_count,
    case when c.target_platforms <> 'all'
         then length(c.target_platforms) - length(replace(c.target_platforms, '|', '')) + 1
    end as target_platform_count,
    case when c.target_server_categories <> 'all'
         then length(c.target_server_categories)
              - length(replace(c.target_server_categories, '|', '')) + 1
    end as target_server_category_count,

    -- A campaign unrestricted on all three axes reaches the whole inventory pool.
    -- Useful for explaining why a campaign wins a disproportionate share of auctions
    -- before anyone concludes its bid is too high.
    (c.target_countries = 'ALL'
     and c.target_platforms = 'all'
     and c.target_server_categories = 'all') as is_unrestricted_targeting,

    coalesce(cr.creative_count, 0)        as creative_count,
    coalesce(cr.creative_format_count, 0) as creative_format_count
from campaigns c
left join advertisers a on c.advertiser_id = a.advertiser_id
left join creatives cr on c.campaign_id = cr.campaign_id
