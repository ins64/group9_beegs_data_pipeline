-- COMPLETENESS: the latest decision must contain the 8 varieties x 8 weeks = 64 rows, never a partial forecast.
select as_of_date, count(*) as n_rows
from {{ ref('gold_supply_coverage_weekly') }}
where as_of_date = (select max(as_of_date) from {{ ref('gold_supply_coverage_weekly') }})
group by 1
having count(*) <> {{ var('horizon_weeks') }} * (select count(*) from {{ ref('honey_varieties') }})
