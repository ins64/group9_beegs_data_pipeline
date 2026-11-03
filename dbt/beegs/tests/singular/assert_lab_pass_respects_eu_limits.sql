-- BUSINESS RULE (EU Honey Directive 2001/110/EC): a lot declared PASS must have moisture <= 20 % and HMF <= 40 mg/kg.
-- A PASS outside the limits = a lab or mapping error: warn, the quality manager checks the lot before it is sold.
{{ config(severity='warn') }}
select sample_id, lot_id, moisture_pct, hmf_mg_kg, verdict
from {{ ref('stg_lims__lab_results') }}
where reject_reason is null and verdict = 'PASS' and (moisture_pct > 20 or hmf_mg_kg > 40)
