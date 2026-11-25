-- A conversion flagged as identity-recovered must have a device that actually
-- resolved. If the flag can be true without a resolution behind it, every number
-- measuring the graph's value is overstated.
select
    c.conversion_id,
    c.conversion_device_id,
    c.is_identity_recovered,
    g.resolved_user_id
from {{ ref('fct_conversions') }} c
left join {{ ref('dim_identity_graph') }} g on c.conversion_device_id = g.device_id
where c.is_identity_recovered
  and (g.resolved_user_id is null or c.user_id <> g.resolved_user_id)
