-- EVIDENCE OF THE PROBLEM: B2B kg ordered vs kg shipped on the requested date, per month and variety.
-- A line counts in the month of its requested delivery date, once it is closed (shipped, partially shipped or lost).
with closed as (
    select *
    from {{ ref('stg_erp__order_lines') }}
    where reject_reason is null and channel = 'B2B'
    qualify row_number() over (partition by order_line_id order by updated_at desc, _loaded_at desc) = 1
)
select
    cast({{ dbt.date_trunc('month', 'requested_delivery_date') }} as date) as delivery_month,
    variety_code,
    count(*)                                                     as order_lines,
    sum(quantity_kg)                                             as ordered_kg,
    sum(shipped_kg)                                              as shipped_kg,
    round(sum(shipped_kg) / nullif(sum(quantity_kg), 0), 4)      as service_level,
    round(sum((quantity_kg - shipped_kg) * unit_price_eur), 0)   as lost_revenue_eur
from closed
where status in ('SHIPPED', 'PARTIALLY_SHIPPED', 'BACKORDER_LOST')
group by 1, 2
