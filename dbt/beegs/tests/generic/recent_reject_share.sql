{#-
  Fails when a source has just delivered broken data. Two conditions, checked on the rows LOADED in the last `days`
  days of loads:
    * one FILE has more than `max_file_share` of its rows rejected (a broken export: wrong columns, wrong format)
    * or, all files together, more than `max_share` of the rows are rejected (a source slowly degrading)
  Attached to the staging models: because it sits UPSTREAM of gold, a failure makes `dbt build` skip every
  downstream model -> a broken file never reaches the decision table (gold keeps yesterday's figures).
-#}
{% test recent_reject_share(model, max_share=0.05, max_file_share=0.5, days=3) %}
with recent as (
    select _source_file, reject_reason
    from {{ model }}
    where _loaded_at >= (select {{ dbt.dateadd('day', -days, 'max(_loaded_at)') }} from {{ model }})
),
per_file as (
    select _source_file, count(*) as n_rows,
           sum(case when reject_reason is not null then 1 else 0 end) as n_rejected
    from recent group by 1
)
select 'file' as scope, _source_file, n_rows, n_rejected
from per_file
where n_rejected > {{ max_file_share }} * n_rows
union all
select 'all recent files', null, sum(n_rows), sum(n_rejected)
from per_file
having sum(n_rejected) > {{ max_share }} * sum(n_rows)
{% endtest %}
