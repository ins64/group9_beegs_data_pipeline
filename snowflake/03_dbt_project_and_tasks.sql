-- =====================================================================================================
-- 03_dbt_project_and_tasks.sql  -  the daily task graph (orchestration INSIDE Snowflake)
--
--   04:17  GitHub Actions (cron) -> extract container: REAL APIs + internal exports -> PUT to @BEEGS.OPS.LANDING
--   06:30  T_ROOT             start of the graph (Europe/Paris)
--            T_LOAD_BATCH       COPY INTO bronze for today's partition (idempotent)
--            T_CHECK_COMPLETE   completeness gate: today's ERP + WMS files MUST be in bronze, else FAIL (dbt skipped,
--                               gold keeps yesterday's correct figures)
--            T_DBT_BUILD        dbt build = models + tests; a failing test skips everything downstream
--          T_FINALIZER        always runs (success or failure): writes the run log, e-mails the data team on failure
--   07:30  A_COVERAGE_RED     business alert to the Head of Sourcing if a variety turned RED (05_quality_and_alerts.sql)
--
-- Why Snowflake tasks and not Airflow: the 3 steps are SQL inside Snowflake; a scheduler that lives where the data
-- lives = nothing to host, no laptop that must stay on, retries + history + graph UI built in. (GitHub Actions only
-- schedules the EXTRACTION, which must run outside Snowflake: trial accounts cannot call external APIs.) Airflow (Cloud Composer
-- ~ 300+ EUR/month) becomes worth it when we orchestrate many systems outside Snowflake. See docs/03_tool_choices.md.
-- =====================================================================================================
USE ROLE BEEGS_ADMIN;
GRANT USAGE ON INTEGRATION BEEGS_EMAIL TO ROLE BEEGS_PIPELINE;   -- the finalizer and the alerts send e-mails
USE ROLE BEEGS_PIPELINE;
USE WAREHOUSE BEEGS_PIPELINE_WH;
USE SCHEMA BEEGS.OPS;

-- ---------- dbt project object ------------------------------------------------------------------------------
-- Deployed by CI on every merge to main (.github/workflows/deploy.yml):
--   snow dbt deploy BEEGS_DBT --source dbt/beegs --database BEEGS --schema OPS --role BEEGS_PIPELINE
-- = a new VERSION of the object BEEGS.OPS.BEEGS_DBT (Snowsight > Transformation > dbt projects, with run history).
-- First build (seeds + full history):  EXECUTE DBT PROJECT BEEGS.OPS.BEEGS_DBT ARGS = 'build --target prod';

-- ---------- run log (one row per graph run, written by the finalizer) ----------------------------------------
CREATE TABLE IF NOT EXISTS OPS.PIPELINE_RUN_LOG (
  graph_run_group_id VARCHAR, run_date DATE, finished_at TIMESTAMP_LTZ, status VARCHAR, failed_tasks VARCHAR, details VARIANT)
  COMMENT = 'Daily pipeline runs (evidence of scheduled cloud execution, C5/C6)';

-- ---------- completeness gate ----------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_CHECK_COMPLETENESS(P_DAY VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  n_erp INTEGER; n_wms INTEGER;
  incomplete EXCEPTION (-20001, 'INCOMPLETE: today''s ERP or WMS export is missing in bronze - dbt not run, gold keeps the last good figures');
BEGIN
  SELECT COUNT(*) INTO :n_erp FROM BEEGS.BRONZE.ERP_ORDER_LINES_RAW WHERE _source_file LIKE '%dt=' || :P_DAY || '/%';
  SELECT COUNT(*) INTO :n_wms FROM BEEGS.BRONZE.WMS_STOCK_RAW      WHERE _source_file LIKE '%dt=' || :P_DAY || '/%';
  IF (:n_erp = 0 OR :n_wms < 50) THEN      -- a WMS snapshot always has hundreds of lots; < 50 = truncated file
    RAISE incomplete;
  END IF;
  RETURN 'complete: erp=' || :n_erp || ' wms=' || :n_wms;
END;
$$;

-- ---------- the graph ------------------------------------------------------------------------------------------
-- The run date is derived from the scheduled time of the graph (not "now" inside each step): a retry at 09:00 still
-- processes the same business day. Data date = yesterday (the extract job exports complete days).
CREATE OR REPLACE TASK T_ROOT
  WAREHOUSE = BEEGS_PIPELINE_WH
  SCHEDULE = 'USING CRON 30 6 * * * Europe/Paris'
  USER_TASK_TIMEOUT_MS = 3600000
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3          -- 3 failed days in a row = stop and page a human, do not loop
  TASK_AUTO_RETRY_ATTEMPTS = 2                 -- transient errors (warehouse, network) retried automatically
  CONFIG = '{"run_mode": "daily"}'
  COMMENT = 'BeeGs daily pipeline - root'
AS
  -- only marks the start of the graph; each child derives the run date from the graph's scheduled time
  -- (SYSTEM$SET_RETURN_VALUE only accepts a constant, so the date cannot be passed down as a return value)
  SELECT 'BeeGs graph started';

CREATE OR REPLACE TASK T_LOAD_BATCH
  WAREHOUSE = BEEGS_PIPELINE_WH
  COMMENT = 'COPY INTO bronze for the run date (files already loaded are skipped: idempotent)'
  AFTER T_ROOT
AS
EXECUTE IMMEDIATE $$
DECLARE
  run_day VARCHAR DEFAULT TO_VARCHAR(DATEADD(day, -1, CONVERT_TIMEZONE('Europe/Paris', SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_ORIGINAL_SCHEDULED_TIMESTAMP')::TIMESTAMP_TZ)::DATE));
  res VARCHAR;
BEGIN
  CALL BEEGS.OPS.SP_LOAD_BATCH(:run_day) INTO :res;
  RETURN run_day || ': ' || res;
END;
$$;

CREATE OR REPLACE TASK T_CHECK_COMPLETE
  WAREHOUSE = BEEGS_PIPELINE_WH
  COMMENT = 'Completeness gate: fail if the day''s ERP/WMS export is missing'
  AFTER T_LOAD_BATCH
AS
EXECUTE IMMEDIATE $$
DECLARE
  run_day VARCHAR DEFAULT TO_VARCHAR(DATEADD(day, -1, CONVERT_TIMEZONE('Europe/Paris', SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_ORIGINAL_SCHEDULED_TIMESTAMP')::TIMESTAMP_TZ)::DATE));
  res VARCHAR;
BEGIN
  CALL BEEGS.OPS.SP_CHECK_COMPLETENESS(:run_day) INTO :res;
  RETURN res;
END;
$$;

CREATE OR REPLACE TASK T_DBT_BUILD
  WAREHOUSE = BEEGS_PIPELINE_WH
  COMMENT = 'dbt build (models + tests). A failed test skips downstream models: bad data never reaches GOLD'
  AFTER T_CHECK_COMPLETE
AS
  EXECUTE DBT PROJECT BEEGS.OPS.BEEGS_DBT ARGS = 'build --target prod';

CREATE OR REPLACE TASK T_FINALIZER
  WAREHOUSE = BEEGS_PIPELINE_WH
  COMMENT = 'Always runs: logs the graph run and e-mails the data team if any task failed'
  FINALIZE = T_ROOT
AS
EXECUTE IMMEDIATE $$
DECLARE
  grp VARCHAR DEFAULT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID');
  failed VARCHAR;
BEGIN
  -- LISTAGG over zero rows returns '' (not NULL): NULLIF, otherwise every run would be logged FAILED
  SELECT NULLIF(LISTAGG(name || ': ' || COALESCE(LEFT(error_message, 200), state), ' | '), '')
    INTO :failed
    FROM TABLE(BEEGS.INFORMATION_SCHEMA.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(hour, -6, CURRENT_TIMESTAMP())))
   WHERE graph_run_group_id = :grp AND state IN ('FAILED', 'CANCELLED', 'SKIPPED') AND name <> 'T_FINALIZER';
  INSERT INTO BEEGS.OPS.PIPELINE_RUN_LOG
    SELECT :grp, DATEADD(day, -1, CURRENT_DATE()), CURRENT_TIMESTAMP(), IFF(:failed IS NULL, 'SUCCESS', 'FAILED'), :failed, NULL;
  IF (:failed IS NOT NULL) THEN
    CALL SYSTEM$SEND_EMAIL('BEEGS_EMAIL', '<<DATA_TEAM_EMAIL>>',
         '[BeeGs pipeline] FAILED run ' || :grp,
         'Failed / skipped tasks: ' || :failed || ' -- GOLD still shows the last successful run. Runbook: docs/05_runbook.md');
  END IF;
  RETURN COALESCE(:failed, 'SUCCESS');
END;
$$;

-- Tasks are created SUSPENDED: resume children first, root last.
ALTER TASK T_FINALIZER      RESUME;
ALTER TASK T_DBT_BUILD      RESUME;
ALTER TASK T_CHECK_COMPLETE RESUME;
ALTER TASK T_LOAD_BATCH     RESUME;
ALTER TASK T_ROOT           RESUME;

-- Run now (demo) instead of waiting for 06:30:   EXECUTE TASK T_ROOT;
-- Watch it:  Snowsight > Monitoring > Task history  (graph view), or
-- SELECT name, state, scheduled_time, completed_time, error_message
--   FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY()) ORDER BY scheduled_time DESC LIMIT 20;
