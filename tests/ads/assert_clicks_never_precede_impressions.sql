-- A click cannot happen before the impression it belongs to. A negative gap is clock
-- skew between collectors or an ordering bug, and either one invalidates every
-- time-based attribution decision downstream.
select click_id, impression_id, impressed_at, clicked_at, seconds_to_click
from {{ ref('fct_ad_clicks') }}
where seconds_to_click < 0
