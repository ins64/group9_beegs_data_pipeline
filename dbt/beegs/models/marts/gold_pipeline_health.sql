-- Freshness and quality per source, shown on the dashboard ("data up to ...") and checked by the freshness alert.
{% set srcs = [('erp_order_lines','ERP_ORDER_LINES_RAW'), ('wms_stock','WMS_STOCK_RAW'), ('hive_events','HIVE_EVENTS_RAW'),
               ('lab_results','LAB_RESULTS_RAW'), ('harvest_declarations','HARVEST_DECLARATIONS_RAW'), ('beekeepers','BEEKEEPERS_RAW'),
               ('erp_customers','ERP_CUSTOMERS_RAW'), ('weather_daily','WEATHER_DAILY_RAW'), ('weather_forecast','WEATHER_FORECAST_RAW'),
               ('fx_rates','FX_RATES_RAW'), ('gbif_bloom','GBIF_BLOOM_RAW'), ('eurostat_honey_imports','EUROSTAT_HONEY_IMPORTS_RAW')] %}
with loads as (
{% for name, tbl in srcs %}
    select '{{ name }}' as source_name, count(*) as bronze_rows, max(_loaded_at) as last_loaded_at
    from {{ source('bronze', tbl) }}
    {% if not loop.last %}union all{% endif %}
{% endfor %}
),
q as (select source_name, count(*) as quarantined_rows from {{ ref('quarantine') }} group by 1)
select l.*, coalesce(q.quarantined_rows, 0) as quarantined_rows,
       round(coalesce(q.quarantined_rows, 0) / nullif(l.bronze_rows, 0), 4) as quarantine_share,
       {{ dbt.current_timestamp() }} as checked_at
from loads l left join q using (source_name)
