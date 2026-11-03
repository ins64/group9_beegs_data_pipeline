-- =====================================================================================================
-- 02_bronze_tables_and_loading.sql  (deployed by CI)  -  BRONZE = what each source said, untouched, + 3 lineage columns
--   _source_file      which file the row came from (replay, debugging, reconciliation)
--   _file_row_number  position in that file
--   _loaded_at        when Snowflake loaded it (freshness checks, "latest version wins" dedup)
-- All CSV columns are VARCHAR on purpose: typing happens in SILVER, where bad values are quarantined
-- instead of making the whole load fail.
-- =====================================================================================================
USE ROLE BEEGS_PIPELINE;
USE WAREHOUSE BEEGS_PIPELINE_WH;
USE SCHEMA BEEGS.BRONZE;

-- ---------- JSON sources: one VARIANT column ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS ERP_ORDER_LINES_RAW   (payload VARIANT, _source_file VARCHAR, _file_row_number NUMBER, _loaded_at TIMESTAMP_LTZ)
  COMMENT = 'ERP B2B/B2C order lines changed each day (JSONL, incremental export with updated_at)';
CREATE TABLE IF NOT EXISTS HIVE_EVENTS_RAW       (payload VARIANT, _source_file VARCHAR, _file_row_number NUMBER, _loaded_at TIMESTAMP_LTZ)
  COMMENT = 'IoT hive scale readings, a file every 4 h -> Snowpipe (resent files and gateway retries: duplicates expected)';
CREATE TABLE IF NOT EXISTS WEATHER_DAILY_RAW     (payload VARIANT, _source_file VARCHAR, _file_row_number NUMBER, _loaded_at TIMESTAMP_LTZ)
  COMMENT = 'Open-Meteo archive API envelopes (REAL data), one per apiary per extraction';
CREATE TABLE IF NOT EXISTS WEATHER_FORECAST_RAW  (payload VARIANT, _source_file VARCHAR, _file_row_number NUMBER, _loaded_at TIMESTAMP_LTZ)
  COMMENT = 'Open-Meteo forecast API envelopes (REAL data), 8 days ahead';
CREATE TABLE IF NOT EXISTS FX_RATES_RAW          (payload VARIANT, _source_file VARCHAR, _file_row_number NUMBER, _loaded_at TIMESTAMP_LTZ)
  COMMENT = 'Frankfurter API (ECB reference rates, REAL data)';
CREATE TABLE IF NOT EXISTS GBIF_BLOOM_RAW        (payload VARIANT, _source_file VARCHAR, _file_row_number NUMBER, _loaded_at TIMESTAMP_LTZ)
  COMMENT = 'GBIF occurrence API, monthly facet per honey plant/country/year (REAL data)';

-- ---------- CSV sources: VARCHAR columns, loaded by column name -------------------------------------
CREATE TABLE IF NOT EXISTS LAB_RESULTS_RAW (
  sample_id VARCHAR, lot_id VARCHAR, lab_name VARCHAR, analysis_date VARCHAR, declared_variety VARCHAR,
  moisture_pct VARCHAR, hmf_mg_kg VARCHAR, pollen_origin_match VARCHAR, c4_sugar_pct VARCHAR, verdict VARCHAR,
  _source_file VARCHAR, _file_row_number NUMBER, _loaded_at TIMESTAMP_LTZ)
  COMMENT = 'Lab analyses (2 partner labs drop a CSV per day) - loaded by Snowpipe within ~1 min';
CREATE TABLE IF NOT EXISTS WMS_STOCK_RAW (
  snapshot_date VARCHAR, lot_id VARCHAR, variety VARCHAR, location VARCHAR, kg_remaining VARCHAR, status VARCHAR,
  received_date VARCHAR, supplier_id VARCHAR,
  _source_file VARCHAR, _file_row_number NUMBER, _loaded_at TIMESTAMP_LTZ)
  COMMENT = 'Warehouse stock: full snapshot of every lot each day';
CREATE TABLE IF NOT EXISTS HARVEST_DECLARATIONS_RAW (
  declaration_id VARCHAR, beekeeper_id VARCHAR, variety VARCHAR, declared_kg VARCHAR, expected_week VARCHAR,
  price_per_kg VARCHAR, currency VARCHAR, declared_at VARCHAR, status VARCHAR, delivered_kg VARCHAR, updated_at VARCHAR,
  _source_file VARCHAR, _file_row_number NUMBER, _loaded_at TIMESTAMP_LTZ)
  COMMENT = 'Beekeeper portal: harvest declarations changed that day (incremental)';
CREATE TABLE IF NOT EXISTS BEEKEEPERS_RAW (
  beekeeper_id VARCHAR, full_name VARCHAR, email VARCHAR, phone VARCHAR, iban VARCHAR, apiary_id VARCHAR,
  country_code VARCHAR, currency VARCHAR, hives_count VARCHAR, is_organic VARCHAR, partner_since VARCHAR,
  _source_file VARCHAR, _file_row_number NUMBER, _loaded_at TIMESTAMP_LTZ)
  COMMENT = 'Beekeeper master data (weekly snapshot). CONTAINS PERSONAL DATA (email, phone, IBAN).';
CREATE TABLE IF NOT EXISTS ERP_CUSTOMERS_RAW (
  customer_id VARCHAR, company_name VARCHAR, segment VARCHAR, country_code VARCHAR, contact_email VARCHAR,
  created_at VARCHAR, main_varieties VARCHAR,
  _source_file VARCHAR, _file_row_number NUMBER, _loaded_at TIMESTAMP_LTZ)
  COMMENT = 'ERP customer master (weekly snapshot)';
CREATE TABLE IF NOT EXISTS EUROSTAT_HONEY_IMPORTS_RAW (
  dataflow VARCHAR, last_update VARCHAR, freq VARCHAR, reporter VARCHAR, partner VARCHAR, product VARCHAR,
  flow VARCHAR, indicators VARCHAR, time_period VARCHAR, obs_value VARCHAR, obs_flag VARCHAR,
  _source_file VARCHAR, _file_row_number NUMBER, _loaded_at TIMESTAMP_LTZ)
  COMMENT = 'Eurostat Comext DS-045409, HS 0409 natural honey, EU27 imports from 9 extra-EU origins (REAL data, SDMX API, twice a month)';

-- =====================================================================================================
-- Micro-batch, event-driven: SNOWPIPE (serverless). An internal stage emits no cloud event, so the producer
-- (extract job) calls the Snowpipe REST API (insertFiles) right after each upload -> loaded within ~1 minute.
-- Used for the 2 sources that arrive during the day and feed quick reactions (lab verdicts, hive readings).
-- =====================================================================================================
USE SCHEMA BEEGS.OPS;

CREATE PIPE IF NOT EXISTS PIPE_LAB_RESULTS
  COMMENT = 'Lab CSV files -> BRONZE.LAB_RESULTS_RAW (notified by the extract job via the Snowpipe REST API)'
AS COPY INTO BEEGS.BRONZE.LAB_RESULTS_RAW
   FROM @BEEGS.OPS.LANDING/lab_results/
   FILE_FORMAT = (FORMAT_NAME = 'BEEGS.OPS.FF_CSV_HEADER')
   MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
   INCLUDE_METADATA = (_source_file = METADATA$FILENAME, _file_row_number = METADATA$FILE_ROW_NUMBER, _loaded_at = METADATA$START_SCAN_TIME)
   ON_ERROR = CONTINUE;

CREATE PIPE IF NOT EXISTS PIPE_HIVE_EVENTS
  COMMENT = 'Hive scale readings (a JSONL file every 4 h) -> BRONZE.HIVE_EVENTS_RAW'
AS COPY INTO BEEGS.BRONZE.HIVE_EVENTS_RAW (payload, _source_file, _file_row_number, _loaded_at)
   FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME
         FROM @BEEGS.OPS.LANDING/hive_events/)
   FILE_FORMAT = (FORMAT_NAME = 'BEEGS.OPS.FF_JSON')
   ON_ERROR = CONTINUE;

-- =====================================================================================================
-- Daily BATCH: COPY INTO run by the task graph (03_dbt_project_and_tasks.sql) after the 04:17 extraction.
-- Idempotent by design: Snowflake remembers which files it loaded (64 days), so a task retry or a
-- manual rerun skips them -> no double counting. A file re-uploaded with different content IS reloaded:
-- silver keeps the latest version per business key (see incident INC-001).
-- p_day = 'YYYY-MM-DD' loads that day's partition only; NULL = every not-yet-loaded file (backfill).
-- =====================================================================================================
CREATE OR REPLACE PROCEDURE SP_LOAD_BATCH(P_DAY VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  pat VARCHAR DEFAULT IFF(:P_DAY IS NULL, '.*', '.*dt=' || :P_DAY || '/.*');
  loaded INTEGER DEFAULT 0;
  n INTEGER;
BEGIN
  -- JSON envelopes (APIs + ERP increments)
  EXECUTE IMMEDIATE 'COPY INTO BEEGS.BRONZE.ERP_ORDER_LINES_RAW (payload, _source_file, _file_row_number, _loaded_at) FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME FROM @BEEGS.OPS.LANDING/erp_order_lines/) FILE_FORMAT = (FORMAT_NAME = ''BEEGS.OPS.FF_JSON'') PATTERN = ''' || pat || ''' ON_ERROR = CONTINUE';
  EXECUTE IMMEDIATE 'COPY INTO BEEGS.BRONZE.WEATHER_DAILY_RAW (payload, _source_file, _file_row_number, _loaded_at) FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME FROM @BEEGS.OPS.LANDING/weather_daily/) FILE_FORMAT = (FORMAT_NAME = ''BEEGS.OPS.FF_JSON'') PATTERN = ''' || pat || ''' ON_ERROR = CONTINUE';
  EXECUTE IMMEDIATE 'COPY INTO BEEGS.BRONZE.WEATHER_FORECAST_RAW (payload, _source_file, _file_row_number, _loaded_at) FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME FROM @BEEGS.OPS.LANDING/weather_forecast/) FILE_FORMAT = (FORMAT_NAME = ''BEEGS.OPS.FF_JSON'') PATTERN = ''' || pat || ''' ON_ERROR = CONTINUE';
  EXECUTE IMMEDIATE 'COPY INTO BEEGS.BRONZE.FX_RATES_RAW (payload, _source_file, _file_row_number, _loaded_at) FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME FROM @BEEGS.OPS.LANDING/fx_rates/) FILE_FORMAT = (FORMAT_NAME = ''BEEGS.OPS.FF_JSON'') PATTERN = ''' || pat || ''' ON_ERROR = CONTINUE';
  EXECUTE IMMEDIATE 'COPY INTO BEEGS.BRONZE.GBIF_BLOOM_RAW (payload, _source_file, _file_row_number, _loaded_at) FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME FROM @BEEGS.OPS.LANDING/gbif_bloom/) FILE_FORMAT = (FORMAT_NAME = ''BEEGS.OPS.FF_JSON'') PATTERN = ''' || pat || ''' ON_ERROR = CONTINUE';
  -- CSV snapshots / increments, by column name
  EXECUTE IMMEDIATE 'COPY INTO BEEGS.BRONZE.WMS_STOCK_RAW FROM @BEEGS.OPS.LANDING/wms_stock/ FILE_FORMAT = (FORMAT_NAME = ''BEEGS.OPS.FF_CSV_HEADER'') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE INCLUDE_METADATA = (_source_file = METADATA$FILENAME, _file_row_number = METADATA$FILE_ROW_NUMBER, _loaded_at = METADATA$START_SCAN_TIME) PATTERN = ''' || pat || ''' ON_ERROR = CONTINUE';
  EXECUTE IMMEDIATE 'COPY INTO BEEGS.BRONZE.HARVEST_DECLARATIONS_RAW FROM @BEEGS.OPS.LANDING/harvest_declarations/ FILE_FORMAT = (FORMAT_NAME = ''BEEGS.OPS.FF_CSV_HEADER'') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE INCLUDE_METADATA = (_source_file = METADATA$FILENAME, _file_row_number = METADATA$FILE_ROW_NUMBER, _loaded_at = METADATA$START_SCAN_TIME) PATTERN = ''' || pat || ''' ON_ERROR = CONTINUE';
  EXECUTE IMMEDIATE 'COPY INTO BEEGS.BRONZE.BEEKEEPERS_RAW FROM @BEEGS.OPS.LANDING/beekeepers/ FILE_FORMAT = (FORMAT_NAME = ''BEEGS.OPS.FF_CSV_HEADER'') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE INCLUDE_METADATA = (_source_file = METADATA$FILENAME, _file_row_number = METADATA$FILE_ROW_NUMBER, _loaded_at = METADATA$START_SCAN_TIME) PATTERN = ''' || pat || ''' ON_ERROR = CONTINUE';
  EXECUTE IMMEDIATE 'COPY INTO BEEGS.BRONZE.ERP_CUSTOMERS_RAW FROM @BEEGS.OPS.LANDING/erp_customers/ FILE_FORMAT = (FORMAT_NAME = ''BEEGS.OPS.FF_CSV_HEADER'') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE INCLUDE_METADATA = (_source_file = METADATA$FILENAME, _file_row_number = METADATA$FILE_ROW_NUMBER, _loaded_at = METADATA$START_SCAN_TIME) PATTERN = ''' || pat || ''' ON_ERROR = CONTINUE';
  -- Backfill only (P_DAY NULL): lab results and hive events of the history, uploaded once to <source>/backfill/.
  -- The daily files of these 2 sources go through Snowpipe (separate load history: no file is loaded twice).
  IF (:P_DAY IS NULL) THEN
    EXECUTE IMMEDIATE 'COPY INTO BEEGS.BRONZE.LAB_RESULTS_RAW FROM @BEEGS.OPS.LANDING/lab_results/backfill/ FILE_FORMAT = (FORMAT_NAME = ''BEEGS.OPS.FF_CSV_HEADER'') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE INCLUDE_METADATA = (_source_file = METADATA$FILENAME, _file_row_number = METADATA$FILE_ROW_NUMBER, _loaded_at = METADATA$START_SCAN_TIME) ON_ERROR = CONTINUE';
    EXECUTE IMMEDIATE 'COPY INTO BEEGS.BRONZE.HIVE_EVENTS_RAW (payload, _source_file, _file_row_number, _loaded_at) FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME FROM @BEEGS.OPS.LANDING/hive_events/backfill/) FILE_FORMAT = (FORMAT_NAME = ''BEEGS.OPS.FF_JSON'') ON_ERROR = CONTINUE';
  END IF;
  -- Eurostat SDMX-CSV: fixed column order defined by Eurostat, header "LAST UPDATE" has a space -> positional
  EXECUTE IMMEDIATE 'COPY INTO BEEGS.BRONZE.EUROSTAT_HONEY_IMPORTS_RAW FROM (SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME FROM @BEEGS.OPS.LANDING/eurostat_honey_imports/) FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = ''"'' ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE) ON_ERROR = CONTINUE';
  SELECT COUNT(*) INTO :n FROM BEEGS.BRONZE.ERP_ORDER_LINES_RAW WHERE _loaded_at >= DATEADD(minute, -30, CURRENT_TIMESTAMP());
  RETURN 'batch load done for ' || COALESCE(:P_DAY, 'ALL') || ' - erp rows loaded in last 30 min: ' || :n;
END;
$$;

-- One-off historical load (backfill) - then the task graph takes over day by day
-- CALL SP_LOAD_BATCH(NULL);
