-- INC-002 (TESTED, failure demonstrated): a lab changes its CSV columns (schema drift).
-- 0. Upload incidents/lab_results_lab_apinov_BROKEN.csv into the landing stage, folder lab_results/dt=2026-10-31/
--    Snowsight: Data > Databases > BEEGS > OPS > Stages > LANDING > "+ Files", path = lab_results/dt=2026-10-31
--    or CLI:    snow stage copy incidents/lab_results_lab_apinov_BROKEN.csv @BEEGS.OPS.LANDING/lab_results/dt=2026-10-31/
--    then announce it to Snowpipe (an internal stage sends no cloud event, the producer triggers the pipe):
ALTER PIPE BEEGS.OPS.PIPE_LAB_RESULTS REFRESH PREFIX = 'dt=2026-10-31/';
USE ROLE BEEGS_PIPELINE; USE WAREHOUSE BEEGS_PIPELINE_WH;

-- 1. Snowpipe loaded it, but the renamed columns arrived NULL
SELECT SYSTEM$PIPE_STATUS('BEEGS.OPS.PIPE_LAB_RESULTS');
SELECT _source_file, COUNT(*), COUNT(verdict) AS with_verdict, COUNT(moisture_pct) AS with_moisture
FROM BEEGS.BRONZE.LAB_RESULTS_RAW WHERE _source_file ILIKE '%BROKEN%' GROUP BY 1;

-- 2. gold timestamp before
SELECT MAX(computed_at) FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY;

-- 3. the pipeline runs -> recent_reject_share_stg_lims__lab_results FAILS, downstream models SKIPPED
EXECUTE TASK BEEGS.OPS.T_ROOT;      -- or: EXECUTE DBT PROJECT BEEGS.OPS.BEEGS_DBT ARGS = 'build --target prod';
SELECT name, state, error_message FROM TABLE(BEEGS.INFORMATION_SCHEMA.TASK_HISTORY()) ORDER BY scheduled_time DESC LIMIT 6;
SELECT * FROM BEEGS.OPS.PIPELINE_RUN_LOG ORDER BY finished_at DESC LIMIT 1;   -- FAILED + e-mail sent

-- 4. gold NOT refreshed (same timestamp as step 2): yesterday's correct figures are still served
SELECT MAX(computed_at) FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY;

-- 5. RECOVERY: the lab re-sends the file with the agreed columns (moisture_pct, verdict) -> latest load per sample wins
--    upload incidents/lab_results_lab_apinov_FIXED.csv to the same folder (Snowsight "+ Files" or snow stage copy), then:
ALTER PIPE BEEGS.OPS.PIPE_LAB_RESULTS REFRESH PREFIX = 'dt=2026-10-31/';
EXECUTE TASK BEEGS.OPS.T_ROOT;
SELECT MAX(computed_at) FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY;          -- refreshed
