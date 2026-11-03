-- Current state of every valid order line (latest version), with its value. Grain: order_line_id.
select
    order_line_id, order_id, customer_id, variety_code, channel, status,
    quantity_kg, shipped_kg, unit_price_eur, round(quantity_kg * unit_price_eur, 2) as line_amount_eur,
    requested_delivery_date, created_at, updated_at
from {{ ref('stg_erp__order_lines') }}
where reject_reason is null
qualify row_number() over (partition by order_line_id order by updated_at desc, _loaded_at desc) = 1
