-- One weight per hive per day (median of valid readings) and the daily gain.
-- A drop of more than 5 kg in a day is a harvest (supers removed) or a manipulation, not a nectar signal: gain set to NULL.
with daily as (
    select hive_id, apiary_id, event_date, median(weight_kg) as weight_kg, count(*) as n_readings
    from {{ ref('stg_iot__hive_events') }}
    where reject_reason is null
    group by 1, 2, 3
),
gains as (
    select *, weight_kg - lag(weight_kg) over (partition by hive_id order by event_date) as raw_gain_kg
    from daily
)
select
    hive_id, apiary_id, event_date, weight_kg, n_readings,
    case when raw_gain_kg < -5 then null else raw_gain_kg end as daily_gain_kg,
    raw_gain_kg < -5 as is_harvest_day
from gains
