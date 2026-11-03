-- ERP customers: latest weekly snapshot wins (a customer missing from the latest snapshot is kept with its last known values)
with ranked as (
    select
        upper(trim(customer_id))                         as customer_id,
        trim(company_name)                               as company_name,
        upper(trim(segment))                             as segment,
        upper(trim(country_code))                        as country_code,
        lower(trim(contact_email))                       as contact_email,
        {{ parse_date_multi('created_at') }}             as customer_since,
        main_varieties,
        _source_file, _loaded_at,
        row_number() over (partition by upper(trim(customer_id)) order by _loaded_at desc, _file_row_number desc) as rn
    from {{ source('bronze', 'ERP_CUSTOMERS_RAW') }}
)
select
    customer_id, company_name, segment, country_code, contact_email, customer_since, main_varieties, _source_file, _loaded_at,
    case when customer_id is null then 'missing_key'
         when segment not in ('FOOD_PRODUCER', 'HOSPITALITY', 'COSMETICS', 'PRIVATE_LABEL') then 'unknown_segment' end as reject_reason
from ranked
where rn = 1
