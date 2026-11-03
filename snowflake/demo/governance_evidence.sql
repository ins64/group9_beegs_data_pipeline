-- Manual evidence queries for the defence (governance). ACCOUNT_USAGE views have up to 3 h of latency.
USE ROLE BEEGS_ADMIN;
USE WAREHOUSE BEEGS_BI_WH;

CALL SYSTEM$CLASSIFY('BEEGS.BRONZE.BEEKEEPERS_RAW', {'auto_tag': false});
CALL SYSTEM$CLASSIFY('BEEGS.BRONZE.ERP_CUSTOMERS_RAW', {'auto_tag': false});   -- contact_email should come out as EMAIL

-- Inventory: what is sensitive, where (evidence for the defence)
SELECT object_database, object_schema, object_name, column_name, tag_name, tag_value
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE object_database = 'BEEGS' AND tag_name IN ('SENSITIVITY', 'DATA_OWNER')
ORDER BY tag_value, object_name;

-- ---------- 3. Audit: who read personal data? (ACCESS_HISTORY, Enterprise) ---------------------------------
SELECT ah.query_start_time, ah.user_name, q.role_name, f.value:"objectName"::varchar AS object_name,
       c.value:"columnName"::varchar AS column_name
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah
JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q ON q.query_id = ah.query_id,
     LATERAL FLATTEN(ah.base_objects_accessed) f,
     LATERAL FLATTEN(f.value:"columns") c
WHERE f.value:"objectName"::varchar ILIKE 'BEEGS.%BEEKEEPER%'
  AND c.value:"columnName"::varchar IN ('EMAIL', 'PHONE', 'IBAN')
  AND ah.query_start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
ORDER BY ah.query_start_time DESC;

-- Who has which role (quarterly access review)
SELECT grantee_name AS user_name, role AS role_name, granted_by, created_on
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
WHERE role LIKE 'BEEGS%' AND deleted_on IS NULL ORDER BY role;

-- ---------- 4. Lineage ---------------------------------------------------------------------------------------
-- Column-level lineage: Snowsight > Catalog > BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY > Lineage
-- Model-level lineage + descriptions: dbt docs (persist_docs puts every description in Snowflake COMMENTs)
SELECT table_schema, table_name, comment FROM BEEGS.INFORMATION_SCHEMA.TABLES WHERE table_schema = 'GOLD';

