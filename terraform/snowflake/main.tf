# =====================================================================================================
# BeeGs - Snowflake platform as code: compute, storage containers, roles and who-can-do-what.
# The objects that live INSIDE the schemas (stages, tables, pipes, tasks, alerts, policies) are versioned SQL
# (snowflake/01..08) and dbt; this file owns the structure and the permissions, which is what drifts in real life.
# =====================================================================================================

# ---------- Compute: one warehouse per workload, so each one's cost is visible ------------------------
resource "snowflake_warehouse" "pipeline" {
  name                         = "BEEGS_PIPELINE_WH"
  warehouse_size               = "XSMALL"
  auto_suspend                 = 60 # seconds: billed per second, 60 s minimum per resume
  auto_resume                  = "true"
  initially_suspended          = true
  statement_timeout_in_seconds = 1800 # a runaway query cannot burn credits for hours
  comment                      = "BeeGs ingestion + transformation (COPY, tasks, dbt). XS: ~250k rows/day."
  lifecycle {
    ignore_changes = [resource_monitor] # attached by ACCOUNTADMIN (00_bootstrap_accountadmin.sql)
  }
}

resource "snowflake_warehouse" "bi" {
  name                         = "BEEGS_BI_WH"
  warehouse_size               = "XSMALL"
  auto_suspend                 = 60
  auto_resume                  = "true"
  initially_suspended          = true
  statement_timeout_in_seconds = 300
  comment                      = "BeeGs consumption (Streamlit, analysts). Separate to see what the dashboard costs."
  lifecycle {
    ignore_changes = [resource_monitor]
  }
}

# ---------- Storage: database + medallion schemas ---------------------------------------------------
resource "snowflake_database" "beegs" {
  name                        = "BEEGS"
  data_retention_time_in_days = 1
  comment                     = "BeeGs data platform - honey supply coverage"
}

locals {
  schemas = {
    BRONZE = { retention = 7, managed = "false", comment = "Raw data exactly as landed (+ _source_file, _loaded_at). COPY / Snowpipe." }
    SILVER = { retention = 1, managed = "false", comment = "Cleaned, typed, deduplicated (dbt staging + intermediate) + quarantine." }
    GOLD   = { retention = 1, managed = "false", comment = "Business marts consumed by the dashboard and the alerts (dbt marts)." }
    OPS    = { retention = 1, managed = "false", comment = "Plumbing: stages, pipes, tasks, dbt project, alerts, audit, FinOps views." }
  }
}

resource "snowflake_schema" "s" {
  for_each                    = local.schemas
  database                    = snowflake_database.beegs.name
  name                        = each.key
  data_retention_time_in_days = each.value.retention # 7 days of Time Travel on raw data = undo a bad load
  with_managed_access         = each.value.managed   # managed access / future grants need MANAGE GRANTS (account-wide):
  # deliberately NOT given to BEEGS_ADMIN (least privilege). dbt grants SELECT on each GOLD table it (re)builds instead.
  comment = each.value.comment
}

# ---------- Functional roles -----------------------------------------------------------------------------
resource "snowflake_account_role" "pipeline" {
  name    = "BEEGS_PIPELINE"
  comment = "Loads bronze, builds silver/gold, owns stages, pipes and tasks. Used by tasks, dbt and the extract job."
}
resource "snowflake_account_role" "purchasing" {
  name    = "BEEGS_PURCHASING"
  comment = "Head of Sourcing: reads GOLD with beekeeper contacts in clear, writes decisions."
}
resource "snowflake_account_role" "analyst" {
  name    = "BEEGS_ANALYST"
  comment = "Read-only GOLD, personal data masked. No access to BRONZE/SILVER."
}

# hierarchy: BEEGS_ADMIN (bootstrap) inherits every functional role
resource "snowflake_grant_account_role" "to_admin" {
  for_each         = { pipeline = snowflake_account_role.pipeline.name, purchasing = snowflake_account_role.purchasing.name, analyst = snowflake_account_role.analyst.name }
  role_name        = each.value
  parent_role_name = "BEEGS_ADMIN"
}

# the extract job's service user may only act as BEEGS_PIPELINE
resource "snowflake_grant_account_role" "pipeline_svc" {
  role_name = snowflake_account_role.pipeline.name
  user_name = "BEEGS_PIPELINE_SVC"
}

# ---------- Warehouses: who may use which compute ----------------------------------------------------------
resource "snowflake_grant_privileges_to_account_role" "pipeline_wh" {
  account_role_name = snowflake_account_role.pipeline.name
  privileges        = ["USAGE", "OPERATE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.pipeline.name
  }
}
resource "snowflake_grant_privileges_to_account_role" "bi_wh" {
  for_each          = { purchasing = snowflake_account_role.purchasing.name, analyst = snowflake_account_role.analyst.name }
  account_role_name = each.value
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.bi.name
  }
}

# ---------- Database & schemas ---------------------------------------------------------------------------
resource "snowflake_grant_privileges_to_account_role" "db_usage" {
  for_each          = { pipeline = snowflake_account_role.pipeline.name, purchasing = snowflake_account_role.purchasing.name, analyst = snowflake_account_role.analyst.name }
  account_role_name = each.value
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.beegs.name
  }
}

# pipeline: builds every layer
resource "snowflake_grant_privileges_to_account_role" "pipeline_layers" {
  for_each          = toset(["BRONZE", "SILVER", "GOLD"])
  account_role_name = snowflake_account_role.pipeline.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE VIEW"]
  on_schema {
    schema_name = snowflake_schema.s[each.key].fully_qualified_name
  }
}
resource "snowflake_grant_privileges_to_account_role" "pipeline_ops" {
  account_role_name = snowflake_account_role.pipeline.name
  privileges = ["USAGE", "CREATE TABLE", "CREATE VIEW", "CREATE STAGE", "CREATE PIPE", "CREATE TASK", "CREATE PROCEDURE",
  "CREATE FILE FORMAT", "CREATE ALERT", "CREATE DBT PROJECT", "CREATE STREAMLIT"]
  on_schema {
    schema_name = snowflake_schema.s["OPS"].fully_qualified_name
  }
}
resource "snowflake_grant_privileges_to_account_role" "pipeline_account" {
  account_role_name = snowflake_account_role.pipeline.name
  privileges        = ["EXECUTE TASK", "EXECUTE MANAGED TASK", "EXECUTE ALERT", "EXECUTE MANAGED ALERT", "EXECUTE DATA METRIC FUNCTION"]
  on_account        = true
}

# consumers: USAGE on GOLD only. SELECT on each table is granted by dbt at build time (post-hook in dbt_project.yml).
resource "snowflake_grant_privileges_to_account_role" "gold_usage" {
  for_each          = { purchasing = snowflake_account_role.purchasing.name, analyst = snowflake_account_role.analyst.name }
  account_role_name = each.value
  privileges        = ["USAGE"]
  on_schema {
    schema_name = snowflake_schema.s["GOLD"].fully_qualified_name
  }
}
