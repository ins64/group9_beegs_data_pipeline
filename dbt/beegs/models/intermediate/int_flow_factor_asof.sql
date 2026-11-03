-- Flow factor applied to the OPEN declarations of an apiary/variety on the decision date:
-- the average flow_index of the weeks of the CURRENT season already observed (week_start <= as_of_date).
-- Before the flow has started (or off-season) there is no evidence yet -> 1.0 (declarations taken as they are).
select apiary_id, variety_code, count(*) as observed_flow_weeks, avg(flow_index) as flow_factor
from {{ ref('int_apiary_flow_weekly') }}
where season_year = extract(year from {{ as_of_date() }})
  and week_start <= {{ add_days(as_of_date(), -6) }}       -- complete weeks only
group by 1, 2
