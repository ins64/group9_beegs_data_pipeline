-- =====================================================================================================
-- 07_governance.sql  -  classification, ownership, audit, lineage, retention
-- Complements 05_security.sql (roles + masking). Deployed by CI as BEEGS_ADMIN, after the first dbt build.
-- =====================================================================================================
-- (deployed by CI as BEEGS_ADMIN; the account-level grants it needs are in 00_bootstrap_accountadmin.sql)
USE ROLE BEEGS_ADMIN;
USE WAREHOUSE BEEGS_PIPELINE_WH;
USE SCHEMA BEEGS.OPS;

-- ---------- 1. Classification tags (one vocabulary for the whole platform) -------------------------------
CREATE TAG IF NOT EXISTS SENSITIVITY ALLOWED_VALUES 'public', 'internal', 'confidential', 'pii'
  COMMENT = 'public: open data (APIs) · internal: business data · confidential: prices/contracts · pii: personal data (GDPR)';
CREATE TAG IF NOT EXISTS DATA_DOMAIN ALLOWED_VALUES 'supply', 'sales', 'quality', 'warehouse', 'iot', 'market', 'reference'
  COMMENT = 'Business domain owning the data';
CREATE TAG IF NOT EXISTS DATA_OWNER COMMENT = 'Accountable business owner (RACI "A"), see docs/09';
CREATE TAG IF NOT EXISTS SOURCE_SYSTEM COMMENT = 'System of record the data comes from';

-- Bronze: every table carries domain, owner, source and sensitivity
ALTER TABLE BEEGS.BRONZE.ERP_ORDER_LINES_RAW        SET TAG DATA_DOMAIN = 'sales',     DATA_OWNER = 'Head of Sales',     SOURCE_SYSTEM = 'ERP',              SENSITIVITY = 'confidential';
ALTER TABLE BEEGS.BRONZE.ERP_CUSTOMERS_RAW          SET TAG DATA_DOMAIN = 'sales',     DATA_OWNER = 'Head of Sales',     SOURCE_SYSTEM = 'ERP',              SENSITIVITY = 'confidential';
ALTER TABLE BEEGS.BRONZE.BEEKEEPERS_RAW             SET TAG DATA_DOMAIN = 'supply',    DATA_OWNER = 'Head of Sourcing',  SOURCE_SYSTEM = 'Beekeeper portal', SENSITIVITY = 'pii';
ALTER TABLE BEEGS.BRONZE.HARVEST_DECLARATIONS_RAW   SET TAG DATA_DOMAIN = 'supply',    DATA_OWNER = 'Head of Sourcing',  SOURCE_SYSTEM = 'Beekeeper portal', SENSITIVITY = 'confidential';
ALTER TABLE BEEGS.BRONZE.LAB_RESULTS_RAW            SET TAG DATA_DOMAIN = 'quality',   DATA_OWNER = 'Quality Manager',   SOURCE_SYSTEM = 'LIMS',             SENSITIVITY = 'internal';
ALTER TABLE BEEGS.BRONZE.WMS_STOCK_RAW              SET TAG DATA_DOMAIN = 'warehouse', DATA_OWNER = 'Warehouse Manager', SOURCE_SYSTEM = 'WMS',              SENSITIVITY = 'internal';
ALTER TABLE BEEGS.BRONZE.HIVE_EVENTS_RAW            SET TAG DATA_DOMAIN = 'iot',       DATA_OWNER = 'Head of Sourcing',  SOURCE_SYSTEM = 'Hive scales',      SENSITIVITY = 'internal';
ALTER TABLE BEEGS.BRONZE.WEATHER_DAILY_RAW          SET TAG DATA_DOMAIN = 'market',    DATA_OWNER = 'Data team',         SOURCE_SYSTEM = 'Open-Meteo',       SENSITIVITY = 'public';
ALTER TABLE BEEGS.BRONZE.WEATHER_FORECAST_RAW       SET TAG DATA_DOMAIN = 'market',    DATA_OWNER = 'Data team',         SOURCE_SYSTEM = 'Open-Meteo',       SENSITIVITY = 'public';
ALTER TABLE BEEGS.BRONZE.FX_RATES_RAW               SET TAG DATA_DOMAIN = 'market',    DATA_OWNER = 'Data team',         SOURCE_SYSTEM = 'ECB/Frankfurter',  SENSITIVITY = 'public';
ALTER TABLE BEEGS.BRONZE.GBIF_BLOOM_RAW             SET TAG DATA_DOMAIN = 'market',    DATA_OWNER = 'Data team',         SOURCE_SYSTEM = 'GBIF',             SENSITIVITY = 'public';
ALTER TABLE BEEGS.BRONZE.EUROSTAT_HONEY_IMPORTS_RAW SET TAG DATA_DOMAIN = 'market',    DATA_OWNER = 'Data team',         SOURCE_SYSTEM = 'Eurostat',         SENSITIVITY = 'public';
-- Column level: the personal data
ALTER TABLE BEEGS.BRONZE.BEEKEEPERS_RAW MODIFY COLUMN email     SET TAG SENSITIVITY = 'pii';
ALTER TABLE BEEGS.BRONZE.BEEKEEPERS_RAW MODIFY COLUMN phone     SET TAG SENSITIVITY = 'pii';
ALTER TABLE BEEGS.BRONZE.BEEKEEPERS_RAW MODIFY COLUMN iban      SET TAG SENSITIVITY = 'pii';
ALTER TABLE BEEGS.BRONZE.BEEKEEPERS_RAW MODIFY COLUMN full_name SET TAG SENSITIVITY = 'pii';
-- Schemas: gold is what consumers may use
ALTER SCHEMA BEEGS.GOLD SET TAG SENSITIVITY = 'confidential', DATA_OWNER = 'Head of Sourcing';

-- ---------- 2. Automatic classification (Snowflake detects PII we may have missed) -------------------------
-- Returns, per column, the detected semantic category (EMAIL, PHONE_NUMBER, NAME, IBAN...) and a confidence.
-- (run in demo/governance_evidence.sql: CALL SYSTEM$CLASSIFY('BEEGS.BRONZE.BEEKEEPERS_RAW', {'auto_tag': false});)

-- ---------- 5. Retention (GDPR: data minimisation & storage limitation) ----------------------------------------
-- Rule (docs/09): personal data of a beekeeper who left the network is deleted 3 years after the last delivery.
-- Bronze keeps the snapshots; this purge is scheduled yearly (1 Jan) and logged.
CREATE OR REPLACE TASK OPS.T_GDPR_PURGE
  WAREHOUSE = BEEGS_PIPELINE_WH
  SCHEDULE = 'USING CRON 0 3 1 1 * Europe/Paris'
  COMMENT = 'GDPR: purge PII of beekeepers inactive for 3 years'
AS
  DELETE FROM BEEGS.BRONZE.BEEKEEPERS_RAW b
  WHERE b.beekeeper_id NOT IN (SELECT DISTINCT beekeeper_id FROM BEEGS.BRONZE.HARVEST_DECLARATIONS_RAW
                               WHERE TRY_TO_DATE(LEFT(updated_at, 10)) >= DATEADD(year, -3, CURRENT_DATE()));
-- (left suspended in the prototype: every simulated beekeeper is active)
