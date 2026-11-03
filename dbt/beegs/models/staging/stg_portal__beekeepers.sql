-- Beekeepers (partner suppliers): latest weekly snapshot. Contains PERSONAL DATA -> masked in GOLD (dim_beekeeper).
-- The IBAN is deliberately NOT propagated beyond this model: no business use in analytics.
with ranked as (
    select
        upper(trim(beekeeper_id))                        as beekeeper_id,
        trim(full_name)                                  as full_name,
        lower(trim(email))                               as email,
        {{ regexp_remove('phone', '[^0-9+]') }}             as phone,
        upper(trim(apiary_id))                           as apiary_id,
        upper(trim(country_code))                        as country_code,
        upper(trim(currency))                            as currency,
        {{ try_number('hives_count') }}                  as hives_count,
        {{ parse_bool('is_organic') }}                   as is_organic,
        {{ parse_date_multi('partner_since') }}          as partner_since,
        _source_file, _loaded_at,
        row_number() over (partition by upper(trim(beekeeper_id)) order by _loaded_at desc, _file_row_number desc) as rn
    from {{ source('bronze', 'BEEKEEPERS_RAW') }}
)
select
    beekeeper_id, full_name, email, phone, apiary_id, country_code, currency, hives_count, is_organic, partner_since,
    _source_file, _loaded_at,
    case when beekeeper_id is null then 'missing_key'
         when currency not in ('EUR', 'HUF', 'RON') then 'unknown_currency' end as reject_reason
from ranked
where rn = 1
