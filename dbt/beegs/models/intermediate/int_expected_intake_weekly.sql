-- Honey expected to ARRIVE in each horizon week, per variety:
--   open declaration kg  x  beekeeper reliability (history)  x  flow factor of his apiary (hive scales + weather + bloom)
-- A declaration whose expected week is already past but still OPEN (late delivery) is expected in week 1.
with open_decl as (
    select d.declaration_id, d.beekeeper_id, d.variety_code, d.declared_kg, d.expected_week_start
    from {{ ref('int_declarations_asof') }} d
    where d.status = 'OPEN'
),
valued as (
    select
        o.variety_code,
        greatest(o.expected_week_start, (select min(week_start) from {{ ref('int_horizon_weeks') }})) as arrival_week_start,
        o.declared_kg,
        coalesce(r.reliability, {{ var('default_reliability') }})            as reliability,
        coalesce(f.flow_factor, 1.0)                                         as flow_factor,
        o.declared_kg * coalesce(r.reliability, {{ var('default_reliability') }}) * coalesce(f.flow_factor, 1.0) as expected_kg
    from open_decl o
    left join {{ ref('int_beekeeper_reliability') }} r on r.beekeeper_id = o.beekeeper_id
    left join {{ ref('int_flow_factor_asof') }} f on f.apiary_id = r.apiary_id and f.variety_code = o.variety_code
)
select
    h.week_number, h.week_start, v.variety_code,
    coalesce(sum(x.declared_kg), 0) as declared_kg,
    coalesce(sum(x.expected_kg), 0) as expected_intake_kg
from {{ ref('int_horizon_weeks') }} h
cross join {{ ref('honey_varieties') }} v
left join valued x on x.variety_code = v.variety_code and x.arrival_week_start = h.week_start
group by 1, 2, 3
