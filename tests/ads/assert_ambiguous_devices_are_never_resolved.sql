-- A network with two different known owners cannot tell us which one an unlinked
-- device belongs to. Resolving it anyway would credit one person's conversions to
-- another — a worse failure than leaving them unattributed, because it corrupts a
-- different campaign's numbers and the labels a ranker trains on.
select device_id, resolution_method, resolved_user_id, candidate_user_count
from {{ ref('dim_identity_graph') }}
where resolution_method = 'ambiguous'
  and resolved_user_id is not null
