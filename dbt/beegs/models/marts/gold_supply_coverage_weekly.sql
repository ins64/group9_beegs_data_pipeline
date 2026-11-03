{#-
  THE DECISION TABLE - "Will we have enough lab-approved honey to serve our B2B contracts in each of the next 8 weeks?"
  Grain: as_of_date x variety_code x week_number (1..8).

  cumulative_supply_kg(w) = released_kg + pending_lab_kg x pass_rate + SUM(expected_intake_kg, weeks 1..w)
  cumulative_demand_kg(w) = SUM(b2b_demand_kg + b2c_reserve_kg, weeks 1..w)
  coverage_ratio(w)       = cumulative_supply_kg / cumulative_demand_kg
  status                  = RED < 0.90 <= AMBER < 1.10 <= GREEN
  shortfall_kg(w)         = GREATEST(cumulative_demand_kg - cumulative_supply_kg, 0)

  INCREMENTAL + MERGE on (as_of_date, variety_code, week_number): every daily run ADDS today's forecast and a rerun of
  the same day REPLACES it -> we keep the history of our forecasts (to measure their accuracy later) and a replay or a
  backfill never double counts.
-#}
{{ config(materialized='incremental', unique_key=['as_of_date', 'variety_code', 'week_number'],
          incremental_strategy=incr_strategy()) }}

with weekly as (
    select
        h.as_of_date, h.week_number, h.week_start, v.variety_code,
        s.stock_snapshot_date, s.released_kg, s.pending_lab_kg, s.pass_rate,
        i.declared_kg                 as declared_intake_kg,
        i.expected_intake_kg,
        d.confirmed_b2b_kg, d.baseline_b2b_kg, d.b2b_demand_kg, d.b2c_reserve_kg
    from {{ ref('int_horizon_weeks') }} h
    cross join {{ ref('honey_varieties') }} v
    join {{ ref('int_supply_position') }} s        on s.variety_code = v.variety_code
    join {{ ref('int_expected_intake_weekly') }} i on i.variety_code = v.variety_code and i.week_number = h.week_number
    join {{ ref('int_demand_weekly') }} d          on d.variety_code = v.variety_code and d.week_number = h.week_number
),
cumulated as (
    select
        *,
        released_kg + pending_lab_kg * pass_rate
          + sum(expected_intake_kg) over (partition by variety_code order by week_number rows between unbounded preceding and current row)
          as cumulative_supply_kg,
        sum(b2b_demand_kg + b2c_reserve_kg) over (partition by variety_code order by week_number rows between unbounded preceding and current row)
          as cumulative_demand_kg
    from weekly
)
select
    as_of_date, variety_code, week_number, week_start, {{ iso_week('week_start') }} as iso_week,
    stock_snapshot_date,
    round(released_kg, 1)            as released_kg,
    round(pending_lab_kg, 1)         as pending_lab_kg,
    round(pass_rate, 4)              as pass_rate,
    round(declared_intake_kg, 1)     as declared_intake_kg,
    round(expected_intake_kg, 1)     as expected_intake_kg,
    round(confirmed_b2b_kg, 1)       as confirmed_b2b_kg,
    round(baseline_b2b_kg, 1)        as baseline_b2b_kg,
    round(b2b_demand_kg, 1)          as b2b_demand_kg,
    round(b2c_reserve_kg, 1)         as b2c_reserve_kg,
    round(cumulative_supply_kg, 1)   as cumulative_supply_kg,
    round(cumulative_demand_kg, 1)   as cumulative_demand_kg,
    round(cumulative_supply_kg / nullif(cumulative_demand_kg, 0), 3) as coverage_ratio,
    case when cumulative_demand_kg = 0                                                then 'GREEN'
         when cumulative_supply_kg / cumulative_demand_kg <  {{ var('red_threshold') }}  then 'RED'
         when cumulative_supply_kg / cumulative_demand_kg <  {{ var('green_threshold') }} then 'AMBER'
         else 'GREEN' end            as coverage_status,
    round(greatest(cumulative_demand_kg - cumulative_supply_kg, 0), 1) as shortfall_kg,
    {{ dbt.current_timestamp() }}    as computed_at
from cumulated
