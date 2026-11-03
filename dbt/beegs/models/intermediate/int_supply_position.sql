-- Supply already in our hands on the decision date, per variety (from the warehouse snapshot of that day):
--   released_kg      lots analysed and PASSED -> sellable now
--   pending_lab_kg   lots received, waiting for the lab (QUARANTINE) -> counted at the variety's pass rate
--   BLOCKED lots (failed lab) and EMPTY lots are excluded.
with snap as (
    select *
    from {{ ref('stg_wms__stock_snapshots') }}
    where reject_reason is null
      and snapshot_date = (select max(snapshot_date) from {{ ref('stg_wms__stock_snapshots') }}
                           where snapshot_date <= {{ as_of_date() }})
)
select
    v.variety_code,
    max(s.snapshot_date)                                                               as stock_snapshot_date,
    coalesce(sum(case when s.status = 'RELEASED'   then s.kg_remaining end), 0)        as released_kg,
    coalesce(sum(case when s.status = 'QUARANTINE' then s.kg_remaining end), 0)        as pending_lab_kg,
    coalesce(sum(case when s.status = 'BLOCKED'    then s.kg_remaining end), 0)        as blocked_kg,
    p.pass_rate
from {{ ref('honey_varieties') }} v
left join snap s using (variety_code)
left join {{ ref('int_lab_pass_rate') }} p using (variety_code)
group by v.variety_code, p.pass_rate
