-- A conversion with no identity, observed or resolved, cannot be credited to anyone.
-- If one is attributed, the candidate join is matching on something other than a
-- person and the attribution is meaningless.
select conversion_id, had_observed_identity, is_identity_recovered, is_attributed
from {{ ref('fct_attributed_conversions') }}
where is_attributed
  and not had_observed_identity
  and not is_identity_recovered
