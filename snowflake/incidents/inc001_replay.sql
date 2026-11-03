-- INC-001 (TESTED): a day's ERP file is loaded a second time -> no double counting in silver / gold.
USE ROLE BEEGS_PIPELINE; USE WAREHOUSE BEEGS_PIPELINE_WH;
SET day = '2026-10-31';

-- 1. BEFORE
SELECT (SELECT COUNT(*) FROM BEEGS.BRONZE.ERP_ORDER_LINES_RAW)        AS bronze_rows,
       (SELECT COUNT(*) FROM BEEGS.SILVER.STG_ERP__ORDER_LINES)       AS silver_versions,
       (SELECT SUM(cumulative_demand_kg) FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY
         WHERE as_of_date = (SELECT MAX(as_of_date) FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY)) AS gold_demand;

-- 2. THE INCIDENT: force the reload of an already-loaded day
COPY INTO BEEGS.BRONZE.ERP_ORDER_LINES_RAW (payload, _source_file, _file_row_number, _loaded_at)
  FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME FROM @BEEGS.OPS.LANDING/erp_order_lines/)
  FILE_FORMAT = (FORMAT_NAME = 'BEEGS.OPS.FF_JSON') PATTERN = '.*dt=2026-10-31/.*' FORCE = TRUE;

-- 3. the normal pipeline runs
EXECUTE DBT PROJECT BEEGS.OPS.BEEGS_DBT ARGS = 'build --target prod';

-- 4. AFTER: bronze has more rows, silver and gold are identical to step 1
SELECT (SELECT COUNT(*) FROM BEEGS.BRONZE.ERP_ORDER_LINES_RAW)        AS bronze_rows,
       (SELECT COUNT(*) FROM BEEGS.SILVER.STG_ERP__ORDER_LINES)       AS silver_versions,
       (SELECT SUM(cumulative_demand_kg) FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY
         WHERE as_of_date = (SELECT MAX(as_of_date) FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY)) AS gold_demand;
