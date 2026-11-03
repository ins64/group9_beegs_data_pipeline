{#-
  Nectar-flow signals per apiary, variety and ISO week, during that variety's flow window only.
  Each signal is compared with the SAME ISO week of the other years (seasonal norm):
    hive_ratio    = avg daily weight gain of the apiary's scales / norm         (weight 0.5 - direct measure)
    weather_ratio = foraging days (REAL Open-Meteo) / norm                      (weight 0.3)
    bloom_ratio   = GBIF observations of the plant this month / prior-years avg (weight 0.2 - REAL GBIF)
  flow_index = 0.5*hive + 0.3*weather + 0.2*bloom, clamped to [0.4, 1.2]. Missing signal = 1 (neutral).
  The weights are an explicit, simple assumption (docs/02_use_case_and_metric.md), to be recalibrated after a season.
-#}
with apiary_variety as (
    select a.apiary_id, a.country_code, v.variety_code, v.flow_start_week, v.flow_end_week
    from {{ ref('apiaries') }} a
    join {{ ref('honey_varieties') }} v
      on '|' || a.main_varieties || '|' like '%|' || v.variety_code || '|%'
),
hive_weekly as (
    select apiary_id, {{ week_start('event_date') }} as week_start, avg(greatest(daily_gain_kg, 0)) as avg_gain_kg
    from {{ ref('int_hive_daily') }}
    group by 1, 2
),
weather_weekly as (
    select apiary_id, {{ week_start('weather_date') }} as week_start,
           sum(case when is_foraging_day then 1 else 0 end) as foraging_days,
           max(case when is_fixture then 1 else 0 end) = 1 as is_fixture
    from {{ ref('stg_meteo__weather_daily') }}
    group by 1, 2
),
weeks as (
    select
        av.apiary_id, av.variety_code, av.country_code,
        w.week_start,
        extract(year from w.week_start)  as season_year,
        extract(month from w.week_start) as month_num,
        cast({{ "weekiso(w.week_start)" if target.type == 'snowflake' else "weekofyear(w.week_start)" }} as integer) as iso_week_num,
        h.avg_gain_kg, w.foraging_days, w.is_fixture
    from apiary_variety av
    join weather_weekly w on w.apiary_id = av.apiary_id
    left join hive_weekly h on h.apiary_id = av.apiary_id and h.week_start = w.week_start
    where cast({{ "weekiso(w.week_start)" if target.type == 'snowflake' else "weekofyear(w.week_start)" }} as integer)
          between av.flow_start_week and av.flow_end_week
),
with_norms as (
    -- seasonal norm = same apiary, variety and ISO week, OTHER years (= window total minus the current year)
    select
        wk.*,
        (sum(avg_gain_kg) over (partition by apiary_id, variety_code, iso_week_num) - coalesce(avg_gain_kg, 0))
          / nullif(count(avg_gain_kg) over (partition by apiary_id, variety_code, iso_week_num)
                   - case when avg_gain_kg is null then 0 else 1 end, 0)                        as norm_gain_kg,
        (sum(foraging_days) over (partition by apiary_id, variety_code, iso_week_num) - foraging_days)
          / nullif(count(*) over (partition by apiary_id, variety_code, iso_week_num) - 1, 0)   as norm_foraging_days
    from weeks wk
),
bloom as (
    select variety_code, country_code, obs_year, obs_month, observations,
           avg(observations) over (partition by variety_code, country_code, obs_month order by obs_year
                                   rows between 3 preceding and 1 preceding) as norm_observations
    from {{ ref('stg_gbif__bloom_monthly') }}
)
select
    n.apiary_id, n.variety_code, n.week_start, n.season_year, n.iso_week_num,
    n.avg_gain_kg, n.norm_gain_kg, n.foraging_days, n.norm_foraging_days,
    b.observations as bloom_observations, b.norm_observations as bloom_norm_observations,
    n.avg_gain_kg / nullif(n.norm_gain_kg, 0)               as hive_ratio,
    n.foraging_days / nullif(n.norm_foraging_days, 0)       as weather_ratio,
    b.observations / nullif(b.norm_observations, 0)         as bloom_ratio,
    least(greatest(
        0.5 * coalesce(n.avg_gain_kg / nullif(n.norm_gain_kg, 0), 1)
      + 0.3 * coalesce(n.foraging_days / nullif(n.norm_foraging_days, 0), 1)
      + 0.2 * coalesce(b.observations / nullif(b.norm_observations, 0), 1), 0.4), 1.2) as flow_index,
    n.is_fixture as weather_is_fixture
from with_norms n
left join bloom b
  on b.variety_code = n.variety_code and b.country_code = n.country_code
 and b.obs_year = n.season_year and b.obs_month = n.month_num
