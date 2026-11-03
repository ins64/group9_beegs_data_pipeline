-- Manual demo (C7): allowed / denied verification. Run in a Snowsight worksheet by a user who has BEEGS_ADMIN.
-- =====================================================================================================
-- VERIFICATION (run during the demo, screenshots in docs/evidence/)
-- =====================================================================================================
-- Secondary roles would add our other roles to the session (and unmask the data): switch them off for the test
USE SECONDARY ROLES NONE;
-- 1) ANALYST: allowed on GOLD, PII masked
USE ROLE BEEGS_ANALYST;  USE WAREHOUSE BEEGS_BI_WH;
SELECT beekeeper_id, full_name, email, phone FROM BEEGS.GOLD.DIM_BEEKEEPER LIMIT 3;     -- email = ***MASKED***
SELECT variety_code, overall_status FROM BEEGS.GOLD.GOLD_COVERAGE_ACTIONS;              -- OK
-- 2) ANALYST: denied on BRONZE / SILVER
SELECT * FROM BEEGS.BRONZE.BEEKEEPERS_RAW LIMIT 1;   -- EXPECTED ERROR: does not exist or not authorized
SELECT * FROM BEEGS.SILVER.QUARANTINE LIMIT 1;       -- EXPECTED ERROR
-- 3) ANALYST: denied on writing decisions
INSERT INTO BEEGS.GOLD.DECISION_LOG (variety_code, action) VALUES ('ACACIA', 'test');   -- EXPECTED ERROR: insufficient privileges
-- 4) PURCHASING: PII in clear, can write a decision
USE ROLE BEEGS_PURCHASING;
SELECT beekeeper_id, full_name, email, phone FROM BEEGS.GOLD.DIM_BEEKEEPER LIMIT 3;     -- clear values
INSERT INTO BEEGS.GOLD.DECISION_LOG (as_of_date, variety_code, action, quantity_kg, comment)
VALUES (CURRENT_DATE(), 'ACACIA', 'BUY FROM PARTNER STOCK', 3900, 'Access test - to delete');
-- 5) Who can see what (audit)
USE ROLE BEEGS_ADMIN;
SHOW GRANTS TO ROLE BEEGS_ANALYST;
SELECT * FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(POLICY_NAME => 'BEEGS.OPS.MASK_PII'));

USE SECONDARY ROLES ALL;
DELETE FROM BEEGS.GOLD.DECISION_LOG WHERE comment = 'Access test - to delete';
