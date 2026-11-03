{#-
  Demand to serve in each horizon week, per variety:
    confirmed_b2b_kg  B2B lines CONFIRMED for delivery that week (overdue confirmed lines are added to week 1)
    baseline_b2b_kg   average weekly B2B volume ordered over the last {{ var('baseline_weeks') }} weeks
                      (the order book is incomplete beyond ~4 weeks: customers call off 2-10 weeks ahead)
    b2b_demand_kg   = GREATEST(confirmed, baseline)
    b2c_reserve_kg    average weekly webshop volume over the last 8 weeks, reserved so B2C is never starved
  Excluded: CANCELLED lines, already SHIPPED lines, rows in quarantine.
-#}
with lines as (select * from {{ ref('int_order_lines_asof') }}),
first_week as (select min(week_start) as w1 from {{ ref('int_horizon_weeks') }}),
confirmed as (
    select variety_code,
           greatest({{ week_start('requested_delivery_date') }}, (select w1 from first_week)) as week_start,
           sum(quantity_kg) as kg
    from lines
    where channel = 'B2B' and status = 'CONFIRMED'
    group by 1, 2
),
baseline as (
    select variety_code, sum(quantity_kg) / {{ var('baseline_weeks') }} as kg_per_week
    from lines
    where channel = 'B2B' and status <> 'CANCELLED'
      and requested_delivery_date >= {{ add_days(as_of_date(), -7 * var('baseline_weeks')) }}
      and requested_delivery_date <  {{ as_of_date() }}
    group by 1
),
b2c as (
    select variety_code, sum(quantity_kg) / 8 as kg_per_week
    from lines
    where channel = 'B2C_WEBSHOP' and status <> 'CANCELLED'
      and requested_delivery_date >= {{ add_days(as_of_date(), -56) }}
      and requested_delivery_date <  {{ as_of_date() }}
    group by 1
)
select
    h.week_number, h.week_start, v.variety_code,
    coalesce(c.kg, 0)                                     as confirmed_b2b_kg,
    coalesce(b.kg_per_week, 0)                            as baseline_b2b_kg,
    greatest(coalesce(c.kg, 0), coalesce(b.kg_per_week, 0)) as b2b_demand_kg,
    coalesce(w.kg_per_week, 0)                            as b2c_reserve_kg
from {{ ref('int_horizon_weeks') }} h
cross join {{ ref('honey_varieties') }} v
left join confirmed c on c.variety_code = v.variety_code and c.week_start = h.week_start
left join baseline b  on b.variety_code = v.variety_code
left join b2c w       on w.variety_code = v.variety_code
