-- B2B customers (ERP). The webshop is one technical customer C0000 (B2C channel), added here so every order line has a customer.
select customer_id, company_name, segment, country_code, customer_since, 'B2B' as channel
from {{ ref('stg_erp__customers') }}
where reject_reason is null
union all
select 'C0000', 'BeeGs webshop (B2C)', 'B2C', 'FR', cast(null as date), 'B2C_WEBSHOP'
