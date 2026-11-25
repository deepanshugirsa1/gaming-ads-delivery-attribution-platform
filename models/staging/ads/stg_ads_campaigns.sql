with source as (
    select * from {{ ads_raw('ads_campaigns') }}
)

select
    cast(campaign_id as string)                 as campaign_id,
    cast(advertiser_id as string)               as advertiser_id,
    cast(campaign_name as string)               as campaign_name,
    lower(cast(objective as string))            as objective,
    lower(cast(quest_format as string))         as quest_format,
    lower(cast(buying_model as string))         as buying_model,
    cast(reward_orbs as int)                    as reward_orbs,
    -- The two reward rules, carried side by side because they are not
    -- interchangeable: a video quest pays out at a seconds threshold, a play or
    -- arena quest at accumulated minutes. Exactly one applies per format.
    cast(completion_threshold_seconds as int)   as completion_threshold_seconds,
    cast(required_playtime_minutes as int)      as required_playtime_minutes,
    lower(cast(bid_strategy as string))         as bid_strategy,
    cast(bid_amount_usd as {{ decimal6() }})    as bid_amount_usd,
    cast(daily_budget_usd as {{ decimal6() }})  as daily_budget_usd,
    cast(start_ts as timestamp)                 as starts_at,
    cast(end_ts as timestamp)                   as ends_at,
    cast(start_ts as date)                      as starts_date,
    cast(end_ts as date)                        as ends_date,
    -- Targeting clauses stay as the source's pipe-delimited text here. Staging
    -- types and renames; interpreting a clause is business logic and belongs in
    -- dim_campaigns, which is also where it can be tested and documented once.
    upper(cast(target_countries as string))     as target_countries,
    lower(cast(target_platforms as string))     as target_platforms,
    lower(cast(target_server_categories as string)) as target_server_categories,
    cast(created_ts as timestamp)               as created_at
from source
