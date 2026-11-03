{{ config(severity="warn") }}
-- MONITORING (warn): if more than 5 % of a source's rows are rejected, the source itself is broken (schema change,
-- export bug...). The build FAILS and gold is not refreshed: better yesterday's correct numbers than today's wrong ones.
-- (hive_events tolerated up to 5 % too: 0 kg readings = sensor faults are expected but must stay rare.)
select source_name, bronze_rows, quarantined_rows, quarantine_share
from {{ ref('gold_pipeline_health') }}
where quarantine_share > {{ var('max_quarantine_share') }}
