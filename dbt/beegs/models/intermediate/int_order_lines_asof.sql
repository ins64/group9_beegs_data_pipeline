-- Order book AS IT WAS KNOWN on the decision date: latest valid version of each line updated on or before as_of_date.
-- (Replaying a past date gives exactly what the buyer could see that day: no look-ahead.)
select *
from {{ ref('stg_erp__order_lines') }}
where reject_reason is null
  and cast(updated_at as date) <= {{ as_of_date() }}
qualify row_number() over (partition by order_line_id order by updated_at desc, _loaded_at desc) = 1
