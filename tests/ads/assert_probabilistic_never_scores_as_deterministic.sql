-- A probabilistic match must never reach the confidence of an observed one, however
-- much evidence accumulates. The two are different kinds of claim, and letting the
-- score collapse the distinction is how a graph starts inventing people.
select device_id, resolution_method, resolution_confidence
from {{ ref('dim_identity_graph') }}
where resolution_method = 'probabilistic'
  and resolution_confidence >= 1.0
