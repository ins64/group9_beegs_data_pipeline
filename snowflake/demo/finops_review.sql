-- Monthly FinOps review queries (manual).
USE ROLE BEEGS_ADMIN;
USE WAREHOUSE BEEGS_BI_WH;

-- ---------- 5. FinOps checks to run every month (or as alerts) --------------------------------------------------
-- (a) top 10 most expensive queries of the month -> optimisation candidates
SELECT query_id, LEFT(query_text, 80) AS query, warehouse_name, ROUND(execution_time / 1000, 1) AS seconds, bytes_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name LIKE 'BEEGS%' AND start_time >= DATE_TRUNC('month', CURRENT_DATE())
ORDER BY execution_time DESC LIMIT 10;
-- (b) idle warehouse time = paid but useless (auto-suspend too long?)
SELECT warehouse_name, ROUND(SUM(credits_used_compute), 3) AS credits_billed,
       ROUND(SUM(credits_attributed_compute_queries), 3) AS credits_used_by_queries,
       ROUND(1 - SUM(credits_attributed_compute_queries) / NULLIF(SUM(credits_used_compute), 0), 3) AS idle_share
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_name LIKE 'BEEGS%' AND start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP()) GROUP BY 1;
