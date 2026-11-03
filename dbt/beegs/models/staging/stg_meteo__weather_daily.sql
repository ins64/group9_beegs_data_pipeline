-- REAL Open-Meteo archive: explode the daily arrays, one row per apiary per day.
-- The extract job re-reads the last 7 days on purpose (ERA5 is revised): the most recent extraction wins.
{{ config(materialized='table') }}
with exploded as (
{% if target.type == 'snowflake' %}
    select
        upper(r.payload:request.apiary_id::varchar)                          as apiary_id,
        get(r.payload:payload.daily.time, f.index)::date                     as weather_date,
        get(r.payload:payload.daily.temperature_2m_max, f.index)::float      as temp_max_c,
        get(r.payload:payload.daily.temperature_2m_min, f.index)::float      as temp_min_c,
        get(r.payload:payload.daily.precipitation_sum, f.index)::float       as precipitation_mm,
        get(r.payload:payload.daily.wind_speed_10m_max, f.index)::float      as wind_max_kmh,
        get(r.payload:payload.daily.sunshine_duration, f.index)::float / 3600.0 as sunshine_hours,
        coalesce(r.payload:fixture::boolean, false)                          as is_fixture,
        r._source_file, r._loaded_at
    from {{ source('bronze', 'WEATHER_DAILY_RAW') }} r,
         lateral flatten(input => r.payload:payload.daily.time) f
{% else %}
    -- DuckDB: unnest the parallel arrays together (zip) - much cheaper than one JSON lookup per element
    select
        upper(json_extract_string(r.payload, '$.request.apiary_id'))                                   as apiary_id,
        cast(unnest(json_extract_string(r.payload, '$.payload.daily.time[*]')) as date)                as weather_date,
        try_cast(unnest(json_extract_string(r.payload, '$.payload.daily.temperature_2m_max[*]')) as double) as temp_max_c,
        try_cast(unnest(json_extract_string(r.payload, '$.payload.daily.temperature_2m_min[*]')) as double) as temp_min_c,
        try_cast(unnest(json_extract_string(r.payload, '$.payload.daily.precipitation_sum[*]')) as double)  as precipitation_mm,
        try_cast(unnest(json_extract_string(r.payload, '$.payload.daily.wind_speed_10m_max[*]')) as double) as wind_max_kmh,
        try_cast(unnest(json_extract_string(r.payload, '$.payload.daily.sunshine_duration[*]')) as double) / 3600.0 as sunshine_hours,
        coalesce(json_extract_string(r.payload, '$.fixture'), 'false') = 'true'                        as is_fixture,
        r._source_file, r._loaded_at
    from {{ source('bronze', 'WEATHER_DAILY_RAW') }} r
{% endif %}
)
select
    *,
    -- Foraging day: bees fly and forage when it is warm, dry and not too windy (beekeeping rule of thumb, assumption)
    (temp_max_c >= 15 and coalesce(precipitation_mm, 0) < 2 and coalesce(wind_max_kmh, 0) < 30) as is_foraging_day
from exploded
where weather_date is not null and temp_max_c is not null   -- ERA5 returns nulls for the last days not computed yet
qualify row_number() over (partition by apiary_id, weather_date order by _loaded_at desc) = 1
