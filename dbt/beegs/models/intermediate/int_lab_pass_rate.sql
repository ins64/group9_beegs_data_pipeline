-- Share of lots passing the lab, per variety, over the 365 days before the decision date.
-- Applied to lots still waiting for their analysis (quarantine): only honey that WILL be sellable counts.
with results as (
    select variety_code, count(*) as n_results, avg(case when verdict = 'PASS' then 1.0 else 0.0 end) as pass_rate
    from {{ ref('stg_lims__lab_results') }}
    where reject_reason is null
      and analysis_date >  {{ add_days(as_of_date(), -365) }}
      and analysis_date <= {{ as_of_date() }}
    group by 1
)
select
    v.variety_code,
    coalesce(r.n_results, 0) as n_results_365d,
    case when coalesce(r.n_results, 0) >= 20 then r.pass_rate else {{ var('default_lab_pass_rate') }} end as pass_rate,
    coalesce(r.n_results, 0) < 20 as is_default_rate
from {{ ref('honey_varieties') }} v
left join results r using (variety_code)
