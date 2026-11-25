-- No conversion may be credited to a touchpoint older than its window allows.
-- This is the test that stops a widened candidate window from leaking into the
-- reported number: candidates are gathered at 28 days, and only this rule keeps the
-- published figure on 7.
select
    conversion_id,
    attribution_type,
    days_from_touchpoint_to_conversion
from {{ ref('fct_attributed_conversions') }}
where is_attributed
  and (
        (attribution_type = 'click' and days_from_touchpoint_to_conversion > {{ var('click_window_days') }})
     or (attribution_type = 'view'  and days_from_touchpoint_to_conversion > {{ var('view_window_days') }})
     or days_from_touchpoint_to_conversion < 0
  )
