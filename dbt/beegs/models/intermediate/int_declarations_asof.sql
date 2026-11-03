-- Harvest declarations as known on the decision date (latest valid version per declaration, no look-ahead).
select *
from {{ ref('stg_portal__harvest_declarations') }}
where reject_reason is null
  and updated_at <= {{ as_of_date() }}
qualify row_number() over (partition by declaration_id order by updated_at desc, _loaded_at desc) = 1
