-- Reaching a later milestone implies reaching every earlier one. A row that
-- completed without passing the third quartile means milestones are being dropped
-- or emitted out of order, which silently breaks every drop-off rate built on them.
select
    impression_id,
    quest_format,
    reached_quartile_25,
    reached_quartile_50,
    reached_quartile_75,
    completed_view
from {{ ref('fct_quest_completions') }}
where (reached_quartile_50 and not reached_quartile_25)
   or (reached_quartile_75 and not reached_quartile_50)
   or (completed_view and not reached_quartile_75)
