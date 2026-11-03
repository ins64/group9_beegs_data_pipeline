-- Delivered / declared kg per beekeeper over the last 365 days (declarations closed as DELIVERED).
-- A beekeeper who declared 1,000 kg and delivered 820 kg has a reliability of 0.82: we apply it to his open declarations.
with closed as (
    select beekeeper_id, sum(delivered_kg) as delivered_kg, sum(declared_kg) as declared_kg, count(*) as n_declarations
    from {{ ref('int_declarations_asof') }}
    where status = 'DELIVERED'
      and updated_at > {{ add_days(as_of_date(), -365) }}
    group by 1
)
select
    b.beekeeper_id,
    b.apiary_id,
    coalesce(c.n_declarations, 0) as n_delivered_365d,
    case when coalesce(c.declared_kg, 0) > 0 then least(c.delivered_kg / c.declared_kg, 1.2)
         else {{ var('default_reliability') }} end as reliability
from {{ ref('stg_portal__beekeepers') }} b
left join closed c using (beekeeper_id)
where b.reject_reason is null
