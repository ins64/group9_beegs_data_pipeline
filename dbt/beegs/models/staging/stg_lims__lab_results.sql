-- Lab results: one analysis per sample. If a lab re-sends a file, the latest load wins.
-- EU Honey Directive 2001/110/EC limits used in tests: moisture <= 20 %, HMF <= 40 mg/kg.
with parsed as (
    select
        upper(trim(sample_id))                         as sample_id,
        upper(trim(lot_id))                            as lot_id,
        upper(trim(lab_name))                          as lab_name,
        {{ parse_date_multi('analysis_date') }}        as analysis_date,
        upper(trim(declared_variety))                  as variety_raw,
        {{ clean_number('moisture_pct') }}             as moisture_pct,
        {{ clean_number('hmf_mg_kg') }}                as hmf_mg_kg,
        {{ parse_bool('pollen_origin_match') }}        as pollen_origin_match,
        {{ clean_number('c4_sugar_pct') }}             as c4_sugar_pct,
        upper(trim(verdict))                           as verdict_raw,
        _source_file, _file_row_number, _loaded_at
    from {{ source('bronze', 'LAB_RESULTS_RAW') }}
)
select
    p.*,
    m.variety_code,
    v.verdict,
    case
        when p.sample_id is null or p.lot_id is null           then 'missing_key'
        when v.verdict is null                                 then 'unknown_verdict'
        when p.analysis_date is null                           then 'invalid_analysis_date'
        when p.moisture_pct is null or p.moisture_pct not between 10 and 30 then 'implausible_moisture'
        when m.variety_code is null                            then 'unknown_variety'
    end as reject_reason
from parsed p
left join {{ ref('variety_label_map') }} m on m.raw_label_upper = p.variety_raw
left join {{ ref('lab_verdict_map') }}   v on v.raw_verdict_upper = p.verdict_raw
qualify row_number() over (partition by p.sample_id order by p._loaded_at desc, p._file_row_number desc) = 1
