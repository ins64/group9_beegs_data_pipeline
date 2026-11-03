{#-
  ONE table with every row we refused to use, from every source, with the reason.
  Nothing disappears silently: data owners get this list; the business-rule test
  assert_quarantine_share_below_threshold fails the build if a source suddenly degrades.
-#}
{{ config(materialized='table') }}
{% set q = [
    ('erp_order_lines',      'stg_erp__order_lines',            'order_line_version_key'),
    ('erp_customers',        'stg_erp__customers',              'customer_id'),
    ('beekeepers',           'stg_portal__beekeepers',          'beekeeper_id'),
    ('harvest_declarations', 'stg_portal__harvest_declarations','declaration_id'),
    ('lab_results',          'stg_lims__lab_results',           'sample_id'),
    ('wms_stock',            'stg_wms__stock_snapshots',        'lot_id'),
    ('hive_events',          'stg_iot__hive_events',            'event_id'),
] %}
{% for source_name, model, key in q %}
select '{{ source_name }}' as source_name, cast({{ key }} as {{ dbt.type_string() }}) as record_key, reject_reason,
       _source_file, _loaded_at
from {{ ref(model) }}
where reject_reason is not null
{% if not loop.last %}union all{% endif %}
{% endfor %}
