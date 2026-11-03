-- REAL ECB reference rates via Frankfurter: {"rates": {"2026-10-01": {"HUF": 391.2, ...}}} -> (date, currency, rate)
{{ config(materialized='table') }}
-- eur_rate = units of currency for 1 EUR. No rate on week-ends / TARGET holidays: downstream takes the last known rate.
{% if target.type == 'snowflake' %}
with exploded as (
    select cast(d.key as date) as rate_date, c.key::varchar as currency, c.value::float as eur_rate, r._loaded_at
    from {{ source('bronze', 'FX_RATES_RAW') }} r,
         lateral flatten(input => r.payload:payload.rates) d,
         lateral flatten(input => d.value) c
)
{% else %}
with exploded as (
    select cast(d.key as date) as rate_date, c.key as currency, try_cast(c.value as double) as eur_rate, r._loaded_at
    from {{ source('bronze', 'FX_RATES_RAW') }} r,
         json_each(r.payload, '$.payload.rates') d,
         json_each(d.value) c
)
{% endif %}
select rate_date, currency, eur_rate, _loaded_at
from exploded
where eur_rate is not null
qualify row_number() over (partition by rate_date, currency order by _loaded_at desc) = 1
