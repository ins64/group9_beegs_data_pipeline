-- Daily stock snapshots from the warehouse (one row per lot per day). Incremental: ~300 new rows a day.
{{ config(materialized='incremental', unique_key=['snapshot_date', 'lot_id'], incremental_strategy=incr_strategy()) }}

with src as (
    select * from {{ source('bronze', 'WMS_STOCK_RAW') }}
    {% if is_incremental() %}
    where _loaded_at > (select coalesce(max(_loaded_at), cast('1900-01-01' as timestamp)) from {{ this }})
    {% endif %}
)
select
    {{ parse_date_multi('snapshot_date') }}       as snapshot_date,
    upper(trim(lot_id))                           as lot_id,
    m.variety_code,
    upper(trim(location))                         as location,
    {{ clean_number('kg_remaining') }}            as kg_remaining,
    upper(trim(status))                           as status,
    {{ parse_date_multi('received_date') }}       as received_date,
    upper(trim(supplier_id))                      as supplier_id,
    _source_file, _loaded_at,
    case
        when lot_id is null                                  then 'missing_key'
        when m.variety_code is null                          then 'unknown_variety'
        when {{ clean_number('kg_remaining') }} is null or {{ clean_number('kg_remaining') }} < 0 then 'invalid_kg'
        when upper(trim(status)) not in ('QUARANTINE', 'RELEASED', 'BLOCKED') then 'unknown_status'
    end as reject_reason
from src
left join {{ ref('variety_label_map') }} m on m.raw_label_upper = upper(trim(src.variety))
qualify row_number() over (partition by {{ parse_date_multi('snapshot_date') }}, upper(trim(lot_id)) order by _loaded_at desc, _file_row_number desc) = 1
