-- Every bid must resolve to a real user, campaign and creative. A null here means a
-- dimension join is failing, and in the feature table that surfaces as a silently
-- null feature rather than a missing row -- the model keeps training, just on less.
select bid_id, user_id, campaign_id, creative_id, account_age_days, objective
from {{ ref('fct_ranking_features') }}
where account_age_days is null
   or objective is null
   or creative_format is null
