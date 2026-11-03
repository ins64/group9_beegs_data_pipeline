-- =====================================================================================================
-- 05_security.sql  (deployed by CI)  -  personal data masking + decision log. Verification: demo/access_verification.sql
-- =====================================================================================================
USE ROLE BEEGS_ADMIN;
USE SCHEMA BEEGS.OPS;

-- Beekeepers' e-mail and phone (GDPR personal data): visible only to the people who need to call them.
CREATE MASKING POLICY IF NOT EXISTS MASK_PII AS (val VARCHAR) RETURNS VARCHAR ->
  CASE
    WHEN IS_ROLE_IN_SESSION('BEEGS_PURCHASING') OR IS_ROLE_IN_SESSION('BEEGS_ADMIN') THEN val
    WHEN val IS NULL THEN NULL
    ELSE '***MASKED***'
  END
  COMMENT = 'PII of beekeepers: clear for purchasing/admin only';
-- The pipeline role re-creates dim_beekeeper every day, so it must be allowed to (re)apply the policy (dbt post-hook).
GRANT APPLY ON MASKING POLICY MASK_PII TO ROLE BEEGS_PIPELINE;

-- Bronze also holds the raw PII (and IBAN): apply the same policy there for anyone who is not the pipeline.
CREATE MASKING POLICY IF NOT EXISTS MASK_PII_RAW AS (val VARCHAR) RETURNS VARCHAR ->
  CASE WHEN IS_ROLE_IN_SESSION('BEEGS_PIPELINE') OR IS_ROLE_IN_SESSION('BEEGS_ADMIN') THEN val ELSE '***MASKED***' END;
ALTER TABLE BEEGS.BRONZE.BEEKEEPERS_RAW MODIFY COLUMN email SET MASKING POLICY MASK_PII_RAW FORCE;
ALTER TABLE BEEGS.BRONZE.BEEKEEPERS_RAW MODIFY COLUMN phone SET MASKING POLICY MASK_PII_RAW FORCE;
ALTER TABLE BEEGS.BRONZE.BEEKEEPERS_RAW MODIFY COLUMN iban  SET MASKING POLICY MASK_PII_RAW FORCE;

-- Purchasing writes its decisions back (closes the loop: decision -> action -> measured outcome)
CREATE TABLE IF NOT EXISTS BEEGS.GOLD.DECISION_LOG (
  decided_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(), decided_by VARCHAR DEFAULT CURRENT_USER(),
  as_of_date DATE, variety_code VARCHAR, action VARCHAR, quantity_kg NUMBER(12,1), comment VARCHAR)
  COMMENT = 'Decisions taken by the Head of Sourcing from the dashboard (SQL INSERT from Streamlit)';
GRANT INSERT, SELECT ON TABLE BEEGS.GOLD.DECISION_LOG TO ROLE BEEGS_PURCHASING;

