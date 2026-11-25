-- How much of the device population the graph can resolve, by platform and method.
--
-- The operating dashboard for identity. Deterministic share is the number to protect:
-- it is the only coverage that costs nothing in accuracy, and the cheapest way to
-- raise total coverage is almost always to make more clients sign in rather than to
-- loosen the probabilistic rule.
--
-- The three unresolved reasons are kept apart because they have different owners.
-- 'ambiguous' is a modelling limit — two known people on one network, and no signal
-- separates them. 'below_threshold' is a tuning decision we made and can revisit.
-- 'no_signal' is a collection gap, and the only one an engineering change fixes.

with graph as (
    select * from {{ ref('dim_identity_graph') }}
),

totals as (
    select count(*) as total_devices from graph
)

select
    g.platform,
    g.resolution_method,
    count(*)                                             as devices,
    t.total_devices,
    {{ safe_div('count(*)', 't.total_devices') }}        as share_of_all_devices,
    sum(case when g.is_resolved then 1 else 0 end)       as resolved_devices,
    avg(g.resolution_confidence)                         as avg_confidence,
    {{ pctl('g.resolution_confidence', 0.50) }}          as p50_confidence,
    sum(g.observed_sessions)                             as observed_sessions,
    sum(case when g.has_advertising_id then 1 else 0 end) as devices_with_advertising_id,
    count(distinct g.resolved_user_id)                   as distinct_users_resolved
from graph g
cross join totals t
group by g.platform, g.resolution_method, t.total_devices
