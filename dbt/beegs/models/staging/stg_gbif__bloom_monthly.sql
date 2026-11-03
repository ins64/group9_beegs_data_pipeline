-- REAL GBIF: number of georeferenced observations of each honey plant per country and month (citizen science).
-- Used as a bloom-intensity signal: this year vs the same month of the previous years.
with exploded as (
    select
        upper({{ json_str('r.payload', 'request.variety') }})                                           as variety_code,
        upper({{ json_str('r.payload', 'request.country') }})                                           as country_code,
        cast({{ json_str('r.payload', 'request.year') }} as integer)                                    as obs_year,
        cast({{ json_array_at('r.payload', 'payload.facets[0].counts', flat_idx('f'), 'name') }} as integer)  as obs_month,
        cast({{ json_array_at('r.payload', 'payload.facets[0].counts', flat_idx('f'), 'count') }} as integer) as observations,
        r._loaded_at
    from {{ source('bronze', 'GBIF_BLOOM_RAW') }} r,
         {{ flatten_array('r.payload', 'payload.facets[0].counts', 'f') }}
)
select * from exploded
qualify row_number() over (partition by variety_code, country_code, obs_year, obs_month order by _loaded_at desc) = 1
