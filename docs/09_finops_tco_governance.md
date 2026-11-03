# 09 · FinOps, TCO and data governance

> Extends docs/07 (security and costs). Costs are **monitored**, not only capped. The 3-year TCO compares our stack with the managed alternatives (Fivetran, dbt Cloud, Cloud Composer). Governance answers *who owns, who sees, who changes, how long we keep*.

## 1. FinOps: the three FinOps phases applied to BeeG's

| Phase | What we do | Where |
|---|---|---|
| **Inform** (visibility) | Every credit is attributed to a service (warehouse, Snowpipe, serverless alerts, data quality, storage), per day, in €. Every dbt query is tagged `beegs_dbt`. | `OPS.FINOPS_DAILY_COST`, `OPS.FINOPS_COST_PER_RUN`, `OPS.FINOPS_UNIT_ECONOMICS`; GitHub Actions minutes in Settings → Billing |
| **Optimize** | XS warehouses with `AUTO_SUSPEND = 60`; serverless alerts instead of warehouse alerts (saves ~12 credits/month); incremental models (only new rows); 10-minute cache in Streamlit; extraction on GitHub Actions within the free quota. Monthly review: top 10 queries + idle share of each warehouse. | `snowflake/08_finops.sql §5` |
| **Operate** (control) | Snowflake **Budget** (10 credits/month, forecast + e-mail, *includes serverless*), **resource monitor** (15 credits, hard suspend), **GitHub spending limit $0**, runbook to shut everything down. | `08_finops.sql §1`, `00_bootstrap_accountadmin.sql` |

**Unit economics** (the KPI the business understands, `OPS.FINOPS_UNIT_ECONOMICS`):

| KPI | Prototype (estimate, to replace by the measured value after one week of runs) |
|---|---|
| Snowflake cost / month | ~4 credits ≈ €14 |
| GitHub Actions / month | €0 (free quota) |
| **Cost per weekly decision** | ≈ **€3.50** |
| Cost per pipeline run | ≈ €0.30 (5 min of XS) |
| Value at stake per decision (2025 average) | €294 k / 52 weeks ≈ **€5.7 k** of B2B revenue per week |

## 2. TCO over 3 years: build (ours) vs managed alternatives

**Assumptions (explicit):** production scale = 10 × the prototype (docs/07 §3). Engineer cost €400/day (blended, loaded). Snowflake ≈ €3.60/credit. Fivetran Standard = $5 base per connection + MAR-based usage; our volume is ~10-20 k MAR/month (distinct rows changed: ~1,500 lots, ~500 order lines, ~4,300 hive events per month). dbt Cloud Starter ≈ $100/developer/month. Cloud Composer 3 small environment ≈ €350/month. Build and maintenance days are our estimates.

| | **A. Our stack** (GitHub Actions container + internal stage + Snowpipe + dbt Project on Snowflake + tasks) | **B. Managed ELT** (Fivetran + dbt Cloud + Snowflake) | **C. Airflow-centric** (Cloud Composer + dbt Core + Snowflake) |
|---|---|---|---|
| Ingestion licence | €0 | ~€30-100/month (4 DB/file connections; the 4 APIs need the Connector SDK = custom code anyway) | €0 |
| Orchestration | €0 (tasks) + GitHub cron (free) | Fivetran schedules + dbt Cloud jobs | ~€350/month (Composer) |
| Transformation | dbt Core in Snowflake (€0 licence) | dbt Cloud 2 seats ~€185/month | dbt Core (€0) |
| Snowflake + extraction run | ~€200/month | ~€190/month | ~€200/month |
| Build (one-off) | 25 days = €10 k | 15 days = €6 k | 30 days = €12 k |
| Maintenance | 2 days/month = €800 | 1 day/month = €400 | 3 days/month = €1,200 |
| **3-year TCO** | **≈ €46 k** | **≈ €35-37.5 k** | **≈ €75 k** |
| Hive scales every 4 h | ✅ micro-batch → Snowpipe | ⚠️ Fivetran syncs every 5-15 min at best | ✅ (via Pub/Sub too) |
| Lock-in | low (open code, raw files kept in the stage) | medium (connectors, MAR pricing changes) | low |

**What the TCO tells us:**
1. **People cost dominates** (54-84 % of every option). Optimising credits matters less than reducing maintenance days.
2. For the **prototype**, our stack is the right choice: €0 licence, it fits the course (dbt Core, Snowflake, IaC), and it handles our 4 niche APIs and the 4-hourly IoT files natively.
3. **Decision rule for production:** when the internal systems become real databases (ERP/WMS on Postgres or SAP), we move the *database* sources to a managed connector (Fivetran or Snowflake Openflow CDC). They are cheap at our MAR volume and cut maintenance. We keep our container for the 4 niche APIs (no native connector exists). We do **not** take Composer before we orchestrate several non-Snowflake systems.
4. Risk to watch with Fivetran: the price is driven by MAR. The daily WMS *full snapshot* would multiply MAR, so we would switch it to change-data-capture first.

## 3. Data governance

### 3.1 Ownership (RACI)

| Data | Accountable (business owner) | Responsible (data) | Consulted | Informed |
|---|---|---|---|---|
| Orders, customers (ERP) | Head of Sales | Philomène | Account managers | Sourcing |
| Beekeepers, harvest declarations (portal) **PII** | Head of Sourcing | Philomène | DPO | Quality |
| Lab results (LIMS) | Quality Manager | Alzira | Labs | Sourcing |
| Stock (WMS) | Warehouse Manager | Alzira | – | Sourcing |
| Hive scales (IoT) | Head of Sourcing | Alzira | Beekeepers | – |
| Open data (weather, FX, GBIF, Eurostat, FranceAgriMer) | Data team | Kelsy | – | – |
| GOLD decision tables | Head of Sourcing | Kelsy | Finance | Management |
| Platform, access, costs | Data team lead | Inès | DPO, Finance | all |

The same ownership is **in the platform**: Snowflake tags `DATA_OWNER`, `DATA_DOMAIN`, `SOURCE_SYSTEM`, `SENSITIVITY` on every bronze table (`snowflake/07_governance.sql`), and a dbt **group** `supply_planning` with an owner on every gold model (`access: public` = the only models meant for consumers).

### 3.2 Classification and protection

| Level | Examples | Protection |
|---|---|---|
| `public` | weather, FX, GBIF, Eurostat | none needed |
| `internal` | stock, lab results, hive weights | roles (no access for outsiders) |
| `confidential` | contract prices, order book, decisions | GOLD only, roles PURCHASING / ANALYST, no sharing outside |
| `pii` | beekeepers' name, e-mail, phone, IBAN | masking policies (BRONZE & GOLD); IBAN never leaves bronze; audit of reads (`ACCESS_HISTORY`); GDPR retention |

`SYSTEM$CLASSIFY` (Snowflake auto-classification) is run on the tables holding people's data, to catch PII we would have missed (e.g. `contact_email` in the customer master).

### 3.3 Data contracts and quality SLAs

| Source | Contract (agreed with the owner) | Enforced by | SLA |
|---|---|---|---|
| Lab CSV | columns `sample_id, lot_id, …, moisture_pct, verdict`; verdict in the agreed vocabulary | `MATCH_BY_COLUMN_NAME` + `recent_reject_share` (INC-002) + `lab_verdict_map` seed | a file within 24 h of the analysis |
| ERP export | one line per change, `updated_at` monotonic, known statuses | accepted values, incremental merge, reconciliation | by 05:30 daily (completeness gate) |
| WMS snapshot | all lots in stock, every day | completeness gate (≥ 50 lots) | by 05:30 daily |
| Hive scales | JSON with `event_id`, `ts`, `weight_kg` | dedup, sensor-fault quarantine, DMFs | a reading every 4 h; alert after 6 h |
| GOLD tables | grain, columns and meaning documented (dbt docs → Snowflake comments) | 78 dbt tests + unit test | refreshed by 07:00 every day |

### 3.4 Lineage, audit, change management, retention

- **Lineage:** dbt DAG (model level) + Snowsight lineage (column level). Every bronze row knows its `_source_file`.
- **Audit:** `ACCESS_HISTORY` shows who read the PII columns (last 30 days); `GRANTS_TO_USERS` is used for a **quarterly access review**; Snowflake query history keeps every query 1 year.
- **Change management:** every change goes through a pull request. CI regenerates the data, runs `dbt build` (79 tests) and reconciles with the answer key, and also runs `terraform validate`. Terraform `plan` is reviewed before `apply`. SQL scripts are numbered and idempotent.
- **Retention (GDPR):** beekeeper personal data is kept for 3 years after the last delivery, then purged (task `T_GDPR_PURGE`, yearly). Bronze has 7 days of Time Travel. Landed files older than 180 days can be removed from the stage (already in bronze). Decision logs are kept 5 years (audit of purchases).
- **Quality as governance:** nothing is deleted silently. `SILVER.QUARANTINE` lists every rejected row with its reason, so the data owner can fix it at the source.
