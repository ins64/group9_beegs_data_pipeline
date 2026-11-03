-- =====================================================================================================
-- 01_stages_and_file_formats.sql  -  the LANDING ZONE (deployed by CI as BEEGS_PIPELINE)
-- Snowflake internal stages replace a cloud bucket: encrypted at rest, versioned access through roles,
-- one folder per source: @BEEGS.OPS.LANDING/<source>/dt=YYYY-MM-DD/<file>
-- =====================================================================================================
USE ROLE BEEGS_PIPELINE;
USE WAREHOUSE BEEGS_PIPELINE_WH;
USE SCHEMA BEEGS.OPS;

CREATE STAGE IF NOT EXISTS LANDING
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')         -- server-side encryption (also required for directory tables / presigned URLs)
  DIRECTORY = (ENABLE = TRUE)                   -- a queryable inventory of every landed file (SELECT * FROM DIRECTORY(@LANDING))
  COMMENT = 'Landing zone: every source lands here as raw files, untouched (replayable). Written by the extract job only.';

CREATE STAGE IF NOT EXISTS EXTRACT_STATE
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Watermarks of the incremental API pulls (last day successfully extracted, per source)';

CREATE FILE FORMAT IF NOT EXISTS FF_JSON
  TYPE = JSON STRIP_OUTER_ARRAY = FALSE
  COMMENT = 'API envelopes, ERP order lines (JSONL), hive events (JSONL)';
CREATE FILE FORMAT IF NOT EXISTS FF_CSV_HEADER
  TYPE = CSV PARSE_HEADER = TRUE FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('') EMPTY_FIELD_AS_NULL = TRUE ENCODING = 'UTF8'
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  COMMENT = 'CSV with header: loaded BY COLUMN NAME so a new/reordered column (schema drift) does not break the load';

-- Inventory of the landing zone (evidence: storage actually traversed by the pipeline)
ALTER STAGE LANDING REFRESH;
SELECT SPLIT_PART(relative_path, '/', 1) AS source, COUNT(*) AS files, ROUND(SUM(size) / 1e6, 1) AS mb, MAX(last_modified) AS last_file
FROM DIRECTORY(@LANDING) GROUP BY 1 ORDER BY 1;
