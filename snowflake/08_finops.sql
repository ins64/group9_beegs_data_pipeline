-- =====================================================================================================
-- 08_finops.sql  -  cost MONITORING (not only limits): who/what spends, per day, per run, per decision
--   * native Snowflake BUDGET on the BeeGs objects (forecast + e-mail before overspending)
--   * OPS.FINOPS_DAILY_COST       : every credit consumed by BeeGs, by service, per day, in EUR
--   * OPS.FINOPS_COST_PER_RUN     : cost of each daily pipeline run (dbt queries are tagged)
--   * OPS.FINOPS_UNIT_ECONOMICS   : cost per weekly decision and per million rows processed
-- Displayed in the Streamlit cockpit (expander "Costs") and in docs/09. GitHub Actions minutes: Settings > Billing.
-- =====================================================================================================
-- (deployed by CI as BEEGS_ADMIN = owner of the database and warehouses, hence APPLYBUDGET; ACCOUNT_USAGE access and
--  BUDGET_CREATOR are granted in 00_bootstrap_accountadmin.sql)
USE ROLE BEEGS_ADMIN;
USE SCHEMA BEEGS.OPS;
USE WAREHOUSE BEEGS_BI_WH;

-- ---------- 1. Native budget (Snowflake Budgets): includes SERVERLESS costs the resource monitor ignores --------
-- (resource monitor = hard stop on warehouses; budget = monitoring + forecast of everything incl. Snowpipe, alerts, DMFs)
CREATE SNOWFLAKE.CORE.BUDGET IF NOT EXISTS BEEGS.OPS.BEEGS_BUDGET();
CALL BEEGS.OPS.BEEGS_BUDGET!SET_SPENDING_LIMIT(10);                                       -- credits / month
-- e-mail when the FORECAST exceeds the limit. Budgets run as the SNOWFLAKE application, which needs the integration.
-- (tolerant: if the grant is refused on this account, the budget still monitors and is visible in Snowsight)
EXECUTE IMMEDIATE $$
BEGIN
  GRANT USAGE ON INTEGRATION BEEGS_EMAIL TO APPLICATION SNOWFLAKE;
  CALL BEEGS.OPS.BEEGS_BUDGET!SET_EMAIL_NOTIFICATIONS('BEEGS_EMAIL', '<<DATA_TEAM_EMAIL>>');
  RETURN 'budget e-mail notifications set';
EXCEPTION WHEN OTHER THEN
  RETURN 'budget e-mail notifications NOT set: ' || SQLERRM;
END;
$$;
CALL BEEGS.OPS.BEEGS_BUDGET!ADD_RESOURCE(SELECT SYSTEM$REFERENCE('DATABASE',  'BEEGS',             'SESSION', 'APPLYBUDGET'));
CALL BEEGS.OPS.BEEGS_BUDGET!ADD_RESOURCE(SELECT SYSTEM$REFERENCE('WAREHOUSE', 'BEEGS_PIPELINE_WH', 'SESSION', 'APPLYBUDGET'));
CALL BEEGS.OPS.BEEGS_BUDGET!ADD_RESOURCE(SELECT SYSTEM$REFERENCE('WAREHOUSE', 'BEEGS_BI_WH',       'SESSION', 'APPLYBUDGET'));

-- ---------- 2. Daily cost by service (EUR) ----------------------------------------------------------------------
-- Price assumption: Enterprise on GCP europe-west2 (our account, London) on-demand ~ 3.90 USD/credit ~ 3.60 EUR/credit (docs/07).
-- ACCOUNT_USAGE has up to 3 h of latency: fine for daily FinOps, not for real-time.
CREATE OR REPLACE VIEW OPS.FINOPS_DAILY_COST
  COMMENT = 'BeeGs credits and EUR per day and per service (warehouses, Snowpipe, alerts, data quality, tasks, storage)'
AS
WITH wh AS (
  SELECT DATE(start_time) AS usage_date, 'warehouse:' || warehouse_name AS service, SUM(credits_used) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE warehouse_name LIKE 'BEEGS%' GROUP BY 1, 2
), pipes AS (
  SELECT DATE(start_time), 'snowpipe:' || pipe_name, SUM(credits_used)
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY WHERE pipe_name LIKE 'PIPE_%' GROUP BY 1, 2
), serverless_tasks AS (     -- serverless alerts are billed here
  SELECT DATE(start_time), 'serverless:' || task_name, SUM(credits_used)
  FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY WHERE database_name = 'BEEGS' GROUP BY 1, 2
), dq AS (
  SELECT DATE(start_time), 'data_quality:' || table_name, SUM(credits_used)
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_QUALITY_MONITORING_USAGE_HISTORY WHERE database_name = 'BEEGS' GROUP BY 1, 2
), storage AS (               -- storage converted to credits-equivalent: ~23 USD / TB / month on GCP EU (assumption)
  SELECT usage_date, 'storage:BEEGS', AVG(average_database_bytes + average_failsafe_bytes) / POWER(1024, 4) * 23 / 30 / 3.90
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY WHERE database_name = 'BEEGS' GROUP BY 1, 2
)
SELECT usage_date, service, ROUND(credits, 5) AS credits, ROUND(credits * 3.60, 4) AS cost_eur
FROM (SELECT * FROM wh UNION ALL SELECT * FROM pipes UNION ALL SELECT * FROM serverless_tasks
      UNION ALL SELECT * FROM dq UNION ALL SELECT * FROM storage);

-- ---------- 3. Cost of each pipeline run (attribution by query tag) ---------------------------------------------
-- dbt sets QUERY_TAG = 'beegs_dbt' (dbt_project.yml), tasks run as BEEGS_PIPELINE: we sum the execution time of
-- their queries and convert with the XS rate (1 credit/h). Approximation: ignores idle seconds before auto-suspend.
CREATE OR REPLACE VIEW OPS.FINOPS_COST_PER_RUN
  COMMENT = 'Approximate cost of each daily pipeline run (sum of query execution time on BEEGS_PIPELINE_WH)'
AS
SELECT DATE(CONVERT_TIMEZONE('Europe/Paris', start_time)) AS run_day,
       COUNT(*)                                                       AS queries,
       SUM(CASE WHEN query_tag = 'beegs_dbt' THEN 1 ELSE 0 END)       AS dbt_queries,
       ROUND(SUM(execution_time) / 1000 / 60, 2)                      AS execution_minutes,
       ROUND(SUM(execution_time) / 1000 / 3600 * 1, 4)                AS approx_credits,
       ROUND(SUM(execution_time) / 1000 / 3600 * 1 * 3.60, 3) AS approx_cost_eur,
       SUM(rows_produced)                                             AS rows_produced
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name = 'BEEGS_PIPELINE_WH' AND role_name = 'BEEGS_PIPELINE'
GROUP BY 1;

-- ---------- 4. Unit economics (the FinOps KPI the business understands) -------------------------------------------
CREATE OR REPLACE VIEW OPS.FINOPS_UNIT_ECONOMICS
  COMMENT = 'Monthly cost, cost per weekly decision, cost per million rows processed'
AS
WITH m AS (SELECT DATE_TRUNC('month', usage_date) AS month, SUM(cost_eur) AS snowflake_eur, SUM(credits) AS credits
           FROM OPS.FINOPS_DAILY_COST GROUP BY 1),
r AS (SELECT DATE_TRUNC('month', run_day) AS month, SUM(rows_produced) AS rows_produced FROM OPS.FINOPS_COST_PER_RUN GROUP BY 1)
SELECT m.month, ROUND(m.credits, 3) AS credits, ROUND(m.snowflake_eur, 2) AS snowflake_eur,
       ROUND(m.snowflake_eur / 4.33, 2)                                   AS eur_per_weekly_decision,
       ROUND(m.snowflake_eur / NULLIF(r.rows_produced / 1e6, 0), 3)       AS eur_per_million_rows
FROM m LEFT JOIN r USING (month) ORDER BY month DESC;

GRANT SELECT ON VIEW OPS.FINOPS_DAILY_COST     TO ROLE BEEGS_PURCHASING;   -- the business sees what its tool costs
GRANT SELECT ON VIEW OPS.FINOPS_UNIT_ECONOMICS TO ROLE BEEGS_PURCHASING;
GRANT USAGE ON SCHEMA BEEGS.OPS TO ROLE BEEGS_PURCHASING;

