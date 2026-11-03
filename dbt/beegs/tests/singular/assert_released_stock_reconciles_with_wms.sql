-- RECONCILIATION: the released stock used in the decision must equal, kg for kg, the sum of RELEASED lots in the
-- warehouse snapshot of the same day. Any gap = a join or a filter bug between silver and gold.
with gold as (
    select variety_code, max(released_kg) as gold_released_kg
    from {{ ref('gold_supply_coverage_weekly') }}
    where as_of_date = (select max(as_of_date) from {{ ref('gold_supply_coverage_weekly') }})
    group by 1
),
wms as (
    select variety_code, sum(kg_remaining) as wms_released_kg
    from {{ ref('stg_wms__stock_snapshots') }}
    where reject_reason is null and status = 'RELEASED'
      and snapshot_date = (select max(as_of_date) from {{ ref('gold_supply_coverage_weekly') }})
    group by 1
)
select g.variety_code, g.gold_released_kg, w.wms_released_kg
from gold g left join wms w using (variety_code)
where abs(g.gold_released_kg - coalesce(w.wms_released_kg, 0)) > 0.5
