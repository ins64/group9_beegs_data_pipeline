-- Pre-flight check before the demo (also run by the GitHub workflow "health-check"). Read-only.
USE ROLE BEEGS_ADMIN;
USE WAREHOUSE BEEGS_BI_WH;
-- 1. Did the pipeline run? (last runs of the task graph, written by the finalizer)
SELECT * FROM BEEGS.OPS.PIPELINE_RUN_LOG ORDER BY 1 DESC LIMIT 5;
-- 2. Bronze volumes
SELECT 'erp_order_lines' t, COUNT(*) n FROM BEEGS.BRONZE.ERP_ORDER_LINES_RAW UNION ALL
SELECT 'wms_stock', COUNT(*) FROM BEEGS.BRONZE.WMS_STOCK_RAW UNION ALL
SELECT 'lab_results', COUNT(*) FROM BEEGS.BRONZE.LAB_RESULTS_RAW UNION ALL
SELECT 'hive_events', COUNT(*) FROM BEEGS.BRONZE.HIVE_EVENTS_RAW UNION ALL
SELECT 'weather_daily', COUNT(*) FROM BEEGS.BRONZE.WEATHER_DAILY_RAW UNION ALL
SELECT 'fx_rates', COUNT(*) FROM BEEGS.BRONZE.FX_RATES_RAW UNION ALL
SELECT 'eurostat', COUNT(*) FROM BEEGS.BRONZE.EUROSTAT_HONEY_IMPORTS_RAW;
-- 3. Decisions kept in GOLD (one block of 64 rows per decision date)
SELECT as_of_date, COUNT(*) AS n_rows, MAX(computed_at) AS computed_at FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY GROUP BY 1 ORDER BY 1;
-- 4. Today's actions
SELECT variety_code, overall_status, first_red_iso_week, max_shortfall_kg, recommended_action FROM BEEGS.GOLD.GOLD_COVERAGE_ACTIONS ORDER BY min_coverage_ratio;
-- 5. Task graph state
SHOW TASKS IN SCHEMA BEEGS.OPS;
-- 7. Incident files (drills / demo) as Snowpipe loaded them, and the pipe state
SELECT _source_file, MIN(_loaded_at) loaded_at, COUNT(*) n_rows, COUNT(verdict) with_verdict
FROM BEEGS.BRONZE.LAB_RESULTS_RAW WHERE _source_file ILIKE '%apinov_%' GROUP BY 1 ORDER BY 2 DESC NULLS FIRST LIMIT 8;
SELECT SYSTEM$PIPE_STATUS('BEEGS.OPS.PIPE_LAB_RESULTS') AS pipe_status;
-- 8. Rejected lab rows in silver (latest version per sample) by file
SELECT _source_file, reject_reason, COUNT(*) n FROM BEEGS.SILVER.STG_LIMS__LAB_RESULTS
WHERE reject_reason IS NOT NULL GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 8;
-- 9. Backtest: what the decision of Monday 30 March 2026 said (compare with docs/evidence)
SELECT variety_code, MIN(coverage_ratio) min_ratio, MIN(IFF(coverage_status = 'RED', iso_week, NULL)) first_red_week
FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY WHERE as_of_date = '2026-03-30' GROUP BY 1 ORDER BY 2;
