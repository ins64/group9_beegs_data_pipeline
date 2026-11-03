-- =====================================================================================================
-- 06_costs_and_teardown.sql  (MANUAL, not deployed by CI)  -  measure what the prototype costs, and switch everything off after the defence
-- =====================================================================================================
USE ROLE ACCOUNTADMIN;

-- ---------- 1. What did we consume? (credits per warehouse, last 30 days) -------------------------------------
SELECT warehouse_name, ROUND(SUM(credits_used), 3) AS credits, ROUND(SUM(credits_used) * 3.0, 2) AS approx_usd_at_3_per_credit
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP()) AND warehouse_name LIKE 'BEEGS%'
GROUP BY 1 ORDER BY 2 DESC;

-- Snowpipe (serverless) credits
SELECT pipe_name, ROUND(SUM(credits_used), 4) AS credits, SUM(files_inserted) AS files, SUM(bytes_inserted) AS bytes
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP()) GROUP BY 1;

-- Storage
SELECT ROUND(AVG(storage_bytes + stage_bytes + failsafe_bytes) / POWER(1024, 3), 3) AS avg_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE WHERE usage_date >= DATEADD(day, -30, CURRENT_DATE());

-- Duration of each daily run (cost driver = minutes of XS warehouse)
SELECT DATE(scheduled_time) AS run_day, name, DATEDIFF(second, query_start_time, completed_time) AS seconds, state
FROM TABLE(BEEGS.INFORMATION_SCHEMA.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(day, -7, CURRENT_TIMESTAMP())))
ORDER BY scheduled_time DESC;

-- Budget guard already in place: resource monitor BEEGS_MONTHLY_RM (00_account_setup.sql): notify 75 %, suspend 100 %.
SHOW RESOURCE MONITORS LIKE 'BEEGS%';

-- =====================================================================================================
-- 2. SHUTDOWN PROCEDURE (after the defence) - in this order, see docs/05_runbook.md section "Shutdown"
-- =====================================================================================================
-- (a) stop the schedule: nothing new is loaded or computed
-- ALTER TASK BEEGS.OPS.T_ROOT SUSPEND;
-- ALTER ALERT BEEGS.OPS.A_COVERAGE_RED SUSPEND;   ALTER ALERT BEEGS.OPS.A_HIVE_FEED_STALE SUSPEND;
-- ALTER PIPE BEEGS.OPS.PIPE_LAB_RESULTS SET PIPE_EXECUTION_PAUSED = TRUE;
-- ALTER PIPE BEEGS.OPS.PIPE_HIVE_EVENTS SET PIPE_EXECUTION_PAUSED = TRUE;
-- (b) GitHub: disable the scheduled workflows (Actions > extract-daily / hive-readings > Disable workflow)
-- (c) delete Snowflake objects (irreversible - export what you want to keep first)
-- DROP DATABASE BEEGS;
-- DROP WAREHOUSE BEEGS_PIPELINE_WH;  DROP WAREHOUSE BEEGS_BI_WH;
--   (or: cd terraform/snowflake && tofu destroy  -> warehouses, database, schemas, roles, grants)
-- DROP INTEGRATION BEEGS_EMAIL;  DROP DATABASE BEEGS_INFRA;  DROP USER BEEGS_DEPLOY_SVC;  DROP USER BEEGS_PIPELINE_SVC;
-- DROP RESOURCE MONITOR BEEGS_MONTHLY_RM;
-- DROP ROLE BEEGS_ANALYST; DROP ROLE BEEGS_PURCHASING; DROP ROLE BEEGS_PIPELINE; DROP ROLE BEEGS_ADMIN;
-- (d) last: the state database BEEGS_INFRA (created by hand), and the 3 GitHub secrets
