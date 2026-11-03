{#-
  Hive scale readings. Pub/Sub delivers AT LEAST ONCE -> duplicates are normal: dedup on event_id.
  Incremental append-only source: only rows loaded since the last run are processed (merge on event_id).
  Firmware quirks handled here: epoch timestamps, key renamed WEIGHT, 0 kg readings = sensor fault (quarantined).
-#}
{{ config(materialized='incremental', unique_key='event_id', incremental_strategy=incr_strategy()) }}

with src as (
    select payload, _source_file, _file_row_number, _loaded_at
    from {{ source('bronze', 'HIVE_EVENTS_RAW') }}
    {% if is_incremental() %}
    where _loaded_at > (select coalesce(max(_loaded_at), cast('1900-01-01' as timestamp)) from {{ this }})
    {% endif %}
),
parsed as (
    select
        {{ json_str('payload', 'event_id') }}                                              as event_id,
        upper({{ json_str('payload', 'hive_id') }})                                        as hive_id,
        upper({{ json_str('payload', 'apiary_id') }})                                      as apiary_id,
        {{ parse_ts(json_str('payload', 'ts')) }}                                          as event_ts,
        coalesce({{ try_number(json_str('payload', 'weight_kg')) }},
                 {{ try_number(json_str('payload', 'WEIGHT')) }})                          as weight_kg,
        {{ try_number(json_str('payload', 'temp_internal_c')) }}                           as temp_internal_c,
        {{ try_number(json_str('payload', 'battery_v')) }}                                 as battery_v,
        _source_file, _file_row_number, _loaded_at
    from src
)
select
    *,
    cast(event_ts as date) as event_date,
    case
        when event_id is null              then 'missing_key'
        when event_ts is null              then 'invalid_timestamp'
        when weight_kg is null             then 'missing_weight'
        when weight_kg <= 5                then 'sensor_fault_weight'
        when weight_kg > 200               then 'implausible_weight'
    end as reject_reason
from parsed
qualify row_number() over (partition by event_id order by _loaded_at, _file_row_number) = 1
