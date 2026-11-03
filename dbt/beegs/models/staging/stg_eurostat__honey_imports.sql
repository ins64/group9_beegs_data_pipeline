-- REAL Eurostat Comext: EU27 imports of natural honey (HS 0409) by extra-EU partner and month.
-- Pivot the 2 indicators -> one row per partner-month with kg and EUR -> unit value EUR/kg = the "spot" price signal.
with clean as (
    select
        upper(trim(partner))                                                 as partner_code,
        cast(left(trim(time_period), 4) || '-' || right(trim(time_period), 2) || '-01' as date) as period_month,
        upper(trim(indicators))                                              as indicator,
        {{ try_number('obs_value') }}                                        as obs_value,
        _loaded_at
    from {{ source('bronze', 'EUROSTAT_HONEY_IMPORTS_RAW') }}
    where trim(product) = '0409' and trim(flow) = '1' and obs_value is not null
    qualify row_number() over (partition by upper(trim(partner)), trim(time_period), upper(trim(indicators)) order by _loaded_at desc) = 1
)
select
    partner_code,
    period_month,
    sum(case when indicator = 'QUANTITY_IN_100KG' then obs_value * 100 end) as quantity_kg,
    sum(case when indicator = 'VALUE_IN_EUROS'   then obs_value end)        as value_eur,
    sum(case when indicator = 'VALUE_IN_EUROS'   then obs_value end)
      / nullif(sum(case when indicator = 'QUANTITY_IN_100KG' then obs_value * 100 end), 0) as unit_value_eur_kg
from clean
group by 1, 2
