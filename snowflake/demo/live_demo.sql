-- =====================================================================================================
-- LIVE DEMO (5 min) - run in a Snowsight worksheet, one block at a time (select the lines, Ctrl/Cmd + Enter).
-- Guide with timings and what to say: docs/11_live_demo.md
-- Prerequisite (done before the defence by the GitHub workflow "demo-prepare"): the broken lab file is parked in
-- @BEEGS.OPS.LANDING/demo_parking/ (a folder no pipe or COPY reads).
-- =====================================================================================================
USE ROLE BEEGS_ADMIN;
USE WAREHOUSE BEEGS_PIPELINE_WH;
USE SCHEMA BEEGS.OPS;

-- ---------- STEP 1 (0:00) - the data landed this morning ---------------------------------------------------
-- rows per source in BRONZE and when they were last loaded (files dropped by the extract container on GitHub Actions)
SELECT 'ERP order lines' AS source, COUNT(*) AS n_rows, MAX(_loaded_at) AS last_load FROM BEEGS.BRONZE.ERP_ORDER_LINES_RAW
UNION ALL SELECT 'WMS stock',        COUNT(*), MAX(_loaded_at) FROM BEEGS.BRONZE.WMS_STOCK_RAW
UNION ALL SELECT 'Lab results',      COUNT(*), MAX(_loaded_at) FROM BEEGS.BRONZE.LAB_RESULTS_RAW
UNION ALL SELECT 'Hive scales (IoT)',COUNT(*), MAX(_loaded_at) FROM BEEGS.BRONZE.HIVE_EVENTS_RAW
UNION ALL SELECT 'Weather (API)',    COUNT(*), MAX(_loaded_at) FROM BEEGS.BRONZE.WEATHER_DAILY_RAW
UNION ALL SELECT 'FX rates (API)',   COUNT(*), MAX(_loaded_at) FROM BEEGS.BRONZE.FX_RATES_RAW
UNION ALL SELECT 'Eurostat (API)',   COUNT(*), MAX(_loaded_at) FROM BEEGS.BRONZE.EUROSTAT_HONEY_IMPORTS_RAW
ORDER BY 1;

-- the last runs of the pipeline (written by the finalizer task)
SELECT run_date, finished_at, status, failed_tasks FROM BEEGS.OPS.PIPELINE_RUN_LOG ORDER BY finished_at DESC LIMIT 3;

-- ---------- STEP 2 (0:45) - INCIDENT: a lab sends a file with renamed columns ------------------------------
-- the file arrives in the lab folder, exactly as the lab's export would drop it ...
COPY FILES INTO @BEEGS.OPS.LANDING/lab_results/dt=2026-10-31/
  FROM @BEEGS.OPS.LANDING/demo_parking/
  PATTERN = '.*BROKEN_live[.]csv';
-- ... and Snowpipe is told to load it (an internal stage sends no cloud event: the producer triggers the pipe)
ALTER PIPE BEEGS.OPS.PIPE_LAB_RESULTS REFRESH PREFIX = 'dt=2026-10-31/';

-- wait ~30 s, then: 60 rows loaded, but the verdict and moisture columns are EMPTY (the lab renamed them)
SELECT _source_file, COUNT(*) AS n_rows, COUNT(verdict) AS with_verdict, COUNT(moisture_pct) AS with_moisture
FROM BEEGS.BRONZE.LAB_RESULTS_RAW
WHERE _source_file ILIKE '%BROKEN_live%'
GROUP BY 1;

-- the decision table BEFORE the run (remember this timestamp)
SELECT MAX(computed_at) AS gold_computed_at FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY;

-- ---------- STEP 3 (1:45) - run the daily pipeline now (instead of waiting for 06:30) -----------------------
EXECUTE TASK BEEGS.OPS.T_ROOT;
-- -> open the second tab: Monitoring > Task History > T_ROOT > graph (it turns green / red live, ~3 min)

-- ---------- STEP 4 (2:00) - meanwhile: the buyer's cockpit (third tab: Projects > Streamlit > COVERAGE_COCKPIT)
-- fallback if the app does not open:
SELECT variety_code, overall_status, first_red_iso_week, max_shortfall_kg, recommended_action,
       cost_partner_option_eur, cost_spot_option_eur
FROM BEEGS.GOLD.GOLD_COVERAGE_ACTIONS ORDER BY min_coverage_ratio;

-- ---------- STEP 5 (4:00) - the run failed SAFELY ----------------------------------------------------------
SELECT name, state, LEFT(error_message, 150) AS error
FROM TABLE(BEEGS.INFORMATION_SCHEMA.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(minute, -15, CURRENT_TIMESTAMP())))
ORDER BY scheduled_time DESC LIMIT 5;
SELECT run_date, finished_at, status, failed_tasks FROM BEEGS.OPS.PIPELINE_RUN_LOG ORDER BY finished_at DESC LIMIT 1;
-- same timestamp as in step 2: Monday's figures were NOT overwritten by bad data
SELECT MAX(computed_at) AS gold_computed_at FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY;

-- =====================================================================================================
-- AFTER THE DEMO (not live): the lab re-sends the agreed format -> the next run is green
-- =====================================================================================================
COPY FILES INTO @BEEGS.OPS.LANDING/lab_results/dt=2026-10-31/
  FROM @BEEGS.OPS.LANDING/demo_parking/
  PATTERN = '.*FIXED_live[.]csv';
ALTER PIPE BEEGS.OPS.PIPE_LAB_RESULTS REFRESH PREFIX = 'dt=2026-10-31/';
-- wait ~30 s
EXECUTE TASK BEEGS.OPS.T_ROOT;
-- ~3 min later: status SUCCESS and a new gold timestamp
SELECT run_date, finished_at, status, failed_tasks FROM BEEGS.OPS.PIPELINE_RUN_LOG ORDER BY finished_at DESC LIMIT 1;
SELECT MAX(computed_at) AS gold_computed_at FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY;
