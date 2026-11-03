-- =====================================================================================================
-- 00_bootstrap_accountadmin.sql  -  the ONLY manual script (run once by a human as ACCOUNTADMIN in Snowsight)
--
-- Everything that needs ACCOUNTADMIN, and nothing else. All the rest is deployed by CI (GitHub Actions):
--   terraform/snowflake  (OpenTofu): warehouses, database, schemas, functional roles, grants
--   snowflake/01..08     (snow sql): stages, bronze tables, pipes, tasks, alerts, security, governance, FinOps
--   dbt/beegs            (snow dbt deploy): the dbt project object
-- Re-runnable (IF NOT EXISTS). Replace the 2 public keys (generated locally: docs/05_runbook.md §2).
-- =====================================================================================================
USE ROLE ACCOUNTADMIN;

-- ---------- 1. The platform owner role (used by the deploy service user and the data engineers) ----------
CREATE ROLE IF NOT EXISTS BEEGS_ADMIN COMMENT = 'Owns every BeeGs object. Granted to the data engineers and to BEEGS_DEPLOY_SVC (CI).';
GRANT ROLE BEEGS_ADMIN TO ROLE SYSADMIN;                                  -- keep the standard hierarchy
GRANT ROLE BEEGS_ADMIN TO USER PCHOLET;                                   -- + the other team members' users
GRANT CREATE DATABASE, CREATE WAREHOUSE, CREATE ROLE ON ACCOUNT TO ROLE BEEGS_ADMIN;
-- account privileges the admin may pass on to the pipeline role (WITH GRANT OPTION, granted by Terraform)
GRANT EXECUTE TASK, EXECUTE MANAGED TASK, EXECUTE ALERT, EXECUTE MANAGED ALERT ON ACCOUNT TO ROLE BEEGS_ADMIN WITH GRANT OPTION;
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE BEEGS_ADMIN WITH GRANT OPTION;
GRANT APPLY MASKING POLICY, APPLY TAG ON ACCOUNT TO ROLE BEEGS_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE BEEGS_ADMIN;
-- governance & FinOps: read ACCOUNT_USAGE (costs, access history), create budgets
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE BEEGS_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.BUDGET_CREATOR TO ROLE BEEGS_ADMIN;

-- ---------- 2. Service users for CI/CD: key pair only, no password, cannot log in to the UI (TYPE = SERVICE) --
CREATE USER IF NOT EXISTS BEEGS_DEPLOY_SVC
  TYPE = SERVICE DEFAULT_ROLE = BEEGS_ADMIN
  RSA_PUBLIC_KEY = '<<DEPLOY_PUBLIC_KEY>>'
  COMMENT = 'GitHub Actions: OpenTofu, SQL scripts, dbt deploy. Private key = GitHub secret SNOWFLAKE_DEPLOY_PRIVATE_KEY';
GRANT ROLE BEEGS_ADMIN TO USER BEEGS_DEPLOY_SVC;
CREATE USER IF NOT EXISTS BEEGS_PIPELINE_SVC
  TYPE = SERVICE
  RSA_PUBLIC_KEY = '<<PIPELINE_PUBLIC_KEY>>'
  COMMENT = 'GitHub Actions extract job: PUT to the landing stage + Snowpipe REST. Role BEEGS_PIPELINE (granted by Terraform)';
-- (its default role BEEGS_PIPELINE is created by Terraform; the job sets the role explicitly)

-- ---------- 3. Infrastructure database: the protected home of the OpenTofu state (created by hand, like a state bucket) --
CREATE DATABASE IF NOT EXISTS BEEGS_INFRA COMMENT = 'Platform plumbing that must exist BEFORE Terraform (state)';
CREATE SCHEMA IF NOT EXISTS BEEGS_INFRA.TFSTATE;
CREATE STAGE IF NOT EXISTS BEEGS_INFRA.TFSTATE.STATE
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'OpenTofu state, client-side encrypted (AES-GCM) + Snowflake server-side encryption, only BEEGS_ADMIN';
GRANT OWNERSHIP ON DATABASE BEEGS_INFRA TO ROLE BEEGS_ADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA BEEGS_INFRA.TFSTATE TO ROLE BEEGS_ADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON STAGE BEEGS_INFRA.TFSTATE.STATE TO ROLE BEEGS_ADMIN COPY CURRENT GRANTS;

-- ---------- 4. Cost guard (only ACCOUNTADMIN can create resource monitors) --------------------------------------
CREATE RESOURCE MONITOR IF NOT EXISTS BEEGS_MONTHLY_RM
  WITH CREDIT_QUOTA = 15 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 75 PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND
           ON 110 PERCENT DO SUSPEND_IMMEDIATE;
-- After the first `tofu apply` (warehouses exist), attach it:
--   ALTER WAREHOUSE BEEGS_PIPELINE_WH SET RESOURCE_MONITOR = BEEGS_MONTHLY_RM;
--   ALTER WAREHOUSE BEEGS_BI_WH       SET RESOURCE_MONITOR = BEEGS_MONTHLY_RM;

-- ---------- 5. E-mail notifications (alerts, pipeline failures, budget) ------------------------------------------
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS BEEGS_EMAIL
  TYPE = EMAIL ENABLED = TRUE
  COMMENT = 'Pipeline failures (data team) and coverage alerts (Head of Sourcing). Recipients = verified e-mails of users';
GRANT USAGE ON INTEGRATION BEEGS_EMAIL TO ROLE BEEGS_ADMIN WITH GRANT OPTION;

-- ---------- 6. Check -------------------------------------------------------------------------------------------
SHOW GRANTS TO ROLE BEEGS_ADMIN;
DESC USER BEEGS_DEPLOY_SVC;     -- RSA_PUBLIC_KEY_FP must be set
