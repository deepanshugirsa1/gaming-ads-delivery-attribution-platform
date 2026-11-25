-- A click is either resolved to its impression or explicitly flagged as an orphan.
-- A row that is neither means the orphan logic silently stopped working and clicks
-- are being dropped from attribution without anyone being told.
select click_id, impression_id, campaign_id, is_orphan
from {{ ref('fct_ad_clicks') }}
where not is_orphan
  and campaign_id is null
