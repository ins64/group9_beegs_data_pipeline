-- Harvest declarations: every version (OPEN -> DELIVERED / CANCELLED). The version valid at a given date is
-- picked downstream (int_declarations_asof) so that past decisions can be replayed.
with parsed as (
    select
        upper(trim(declaration_id))                          as declaration_id,
        upper(trim(beekeeper_id))                            as beekeeper_id,
        upper(trim(variety))                                 as variety_raw,
        {{ clean_number('declared_kg') }}                    as declared_kg,
        upper(trim(expected_week))                           as expected_week,
        {{ clean_number('price_per_kg') }}                   as price_per_kg_local,
        upper(trim(currency))                                as currency,
        {{ parse_date_multi('declared_at') }}                as declared_at,
        upper(trim(status))                                  as status,
        coalesce({{ clean_number('delivered_kg') }}, 0)      as delivered_kg,
        {{ parse_date_multi('updated_at') }}                 as updated_at,
        _source_file, _file_row_number, _loaded_at
    from {{ source('bronze', 'HARVEST_DECLARATIONS_RAW') }}
)
select
    p.*,
    m.variety_code,
    case when p.expected_week like '____-W__' then {{ iso_week_to_monday('p.expected_week') }} end as expected_week_start,
    case
        when p.declaration_id is null                         then 'missing_key'
        when m.variety_code is null                           then 'unknown_variety'
        when p.declared_kg is null or p.declared_kg <= 0      then 'invalid_declared_kg'
        when p.expected_week not like '____-W__'              then 'invalid_expected_week'
        when p.status not in ('OPEN', 'DELIVERED', 'CANCELLED') then 'unknown_status'
        when p.updated_at is null                             then 'invalid_updated_at'
    end as reject_reason
from parsed p
left join {{ ref('variety_label_map') }} m on m.raw_label_upper = p.variety_raw
qualify row_number() over (partition by p.declaration_id, p.updated_at, p.status order by p._loaded_at desc, p._file_row_number desc) = 1
