-- REAL Open-Meteo forecast: only the latest forecast run per apiary is relevant.
with exploded as (
    select
        upper({{ json_str('r.payload', 'request.apiary_id') }})                                   as apiary_id,
        cast({{ json_str('r.payload', 'run_date') }} as date)                                      as forecast_run_date,
        cast({{ json_array_at('r.payload', 'payload.daily.time', flat_idx('f')) }} as date)        as forecast_date,
        {{ try_number(json_array_at('r.payload', 'payload.daily.temperature_2m_max', flat_idx('f'))) }} as temp_max_c,
        {{ try_number(json_array_at('r.payload', 'payload.daily.precipitation_sum', flat_idx('f'))) }}  as precipitation_mm,
        {{ try_number(json_array_at('r.payload', 'payload.daily.wind_speed_10m_max', flat_idx('f'))) }} as wind_max_kmh,
        r._loaded_at
    from {{ source('bronze', 'WEATHER_FORECAST_RAW') }} r,
         {{ flatten_array('r.payload', 'payload.daily.time', 'f') }}
)
select *, (temp_max_c >= 15 and coalesce(precipitation_mm, 0) < 2 and coalesce(wind_max_kmh, 0) < 30) as is_foraging_day
from exploded
qualify dense_rank() over (partition by apiary_id order by forecast_run_date desc, _loaded_at desc) = 1
