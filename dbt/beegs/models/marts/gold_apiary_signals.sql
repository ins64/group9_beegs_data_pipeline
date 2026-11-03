-- Season signals per apiary and variety for the dashboard: observed flow this season + foraging days forecast (REAL Open-Meteo).
with fc as (
    select apiary_id, sum(case when is_foraging_day then 1 else 0 end) as forecast_foraging_days_8d, max(forecast_run_date) as forecast_run_date
    from {{ ref('stg_meteo__weather_forecast') }}
    group by 1
)
select
    a.apiary_id, a.apiary_name, a.region, a.country_code, a.latitude, a.longitude,
    f.variety_code, f.observed_flow_weeks, round(f.flow_factor, 3) as flow_factor_this_season,
    fc.forecast_foraging_days_8d, fc.forecast_run_date
from {{ ref('apiaries') }} a
left join {{ ref('int_flow_factor_asof') }} f using (apiary_id)
left join fc using (apiary_id)
