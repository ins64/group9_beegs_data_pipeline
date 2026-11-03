{#-
  ERP order lines - every VERSION of every line (the ERP exports a line again each time it changes).
  INCREMENTAL: each run only reads bronze rows loaded since the last run (_loaded_at watermark) and MERGEs them
  on (order_line_id, updated_at). Reloading the same file, or Pub/Sub-style duplicates, cannot double count.
  Rows that cannot be trusted keep a reject_reason and are routed to the quarantine model, not dropped silently.
-#}
{{ config(materialized='incremental', unique_key='order_line_version_key', incremental_strategy=incr_strategy(),
          on_schema_change='append_new_columns') }}

with src as (
    select payload, _source_file, _file_row_number, _loaded_at
    from {{ source('bronze', 'ERP_ORDER_LINES_RAW') }}
    {% if is_incremental() %}
    where _loaded_at > (select coalesce(max(_loaded_at), cast('1900-01-01' as timestamp)) from {{ this }})
    {% endif %}
),

parsed as (
    select
        trim({{ json_str('payload', 'order_line_id') }})                         as order_line_id,
        trim({{ json_str('payload', 'order_id') }})                              as order_id,
        upper(trim({{ json_str('payload', 'customer_id') }}))                    as customer_id,
        upper(trim({{ json_str('payload', 'variety') }}))                        as variety_raw,
        {{ clean_number(json_str('payload', 'quantity_kg')) }}                   as quantity_kg,
        {{ clean_number(json_str('payload', 'shipped_kg')) }}                    as shipped_kg,
        {{ clean_number(json_str('payload', 'unit_price_eur')) }}                as unit_price_eur,
        {{ parse_date_multi(json_str('payload', 'requested_delivery_date')) }}   as requested_delivery_date,
        upper(trim({{ json_str('payload', 'status') }}))                         as status,
        upper(trim({{ json_str('payload', 'channel') }}))                        as channel,
        {{ parse_ts(json_str('payload', 'created_at')) }}                        as created_at,
        {{ parse_ts(json_str('payload', 'updated_at')) }}                        as updated_at,
        _source_file, _file_row_number, _loaded_at
    from src
),

checked as (
    select
        p.*,
        m.variety_code,
        p.order_line_id || '|' || coalesce(cast(p.updated_at as {{ dbt.type_string() }}), '?') as order_line_version_key,
        case
            when p.order_line_id is null                         then 'missing_key'
            when p.updated_at is null                            then 'invalid_updated_at'
            when m.variety_code is null                          then 'unknown_variety'
            when p.quantity_kg is null or p.quantity_kg <= 0     then 'invalid_quantity'
            when p.quantity_kg > 50000                           then 'implausible_quantity'
            when p.requested_delivery_date is null               then 'invalid_delivery_date'
            when p.status not in ('CONFIRMED', 'CANCELLED', 'SHIPPED', 'PARTIALLY_SHIPPED', 'BACKORDER_LOST') then 'unknown_status'
            when p.channel not in ('B2B', 'B2C_WEBSHOP')         then 'unknown_channel'
        end as reject_reason
    from parsed p
    left join {{ ref('variety_label_map') }} m on m.raw_label_upper = p.variety_raw
)

select * from checked
-- exact duplicates inside one batch (same line, same version): keep the last loaded copy
qualify row_number() over (partition by order_line_version_key order by _loaded_at desc, _file_row_number desc) = 1
