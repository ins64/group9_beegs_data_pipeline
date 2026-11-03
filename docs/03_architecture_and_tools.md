# 03 · Architecture, sources, ingestion and tool choices

> Criteria C3, C4 and C5. Each arrow of the diagram (`architecture/beegs_architecture.excalidraw`) is listed here with its method and why.

## 1. Overview: Snowflake-centric, cloud-native, no server to run

```
 SOURCES (12)                        COMPUTE (GitHub Actions runners)            SNOWFLAKE (on Google Cloud europe-west2, London)                    CONSUMPTION
 ────────────────────────────────    ─────────────────────────────────────────   ───────────────────────────────────────────────────────────────    ─────────────────────
 REAL  Open-Meteo archive ─┐
 REAL  Open-Meteo forecast ─┤        extract container (GHCR image, versioned)    @OPS.LANDING  (internal stage = landing zone)
 REAL  Frankfurter (ECB FX)─┼──►     task "apis": API pull, watermark   ──PUT──►  <source>/dt=YYYY-MM-DD/<file>          ┌BRONZE┐ dbt ┌SILVER┐ dbt ┌GOLD┐
 REAL  GBIF occurrences ───┘         cron 03:17 UTC (04:17 Paris)                                    │                    │ raw +│ ──► │typed,│ ──► │marts│──► Streamlit cockpit
 REAL  Eurostat Comext ───── same container: SDMX API, 1st+15th ─────PUT──►                          ├─ COPY INTO (task) ►│ lin- │     │dedup,│     │     │──► Alert e-mail (RED)
 REAL  FranceAgriMer 2024 ── dbt seed (versioned in Git) ──────────────────────────────────────────────────────────────────────►│quar. │     │     │──► Decision log (INSERT)
 SIM   ERP / WMS / portal ─┐         task "internal": daily exports     ──PUT──►                          │                    │ eage │     └──────┘     └─────┘
 SIM   LIMS lab results ───┘         + REFRESH pipe (lab files)          ──────►  ├─ Snowpipe (~1 min) ►│      │
 SIM   IoT hive scales ─────────     task "hive": every 4 h + REFRESH pipe ─────►  └─ Snowpipe (~1 min) ►└──────┘
                                                                                  task graph 06:30: ROOT → LOAD_BATCH → CHECK_COMPLETE → DBT_BUILD (+ FINALIZER)
 IaC: OpenTofu (terraform/snowflake) · state encrypted (AES-GCM) in @BEEGS_INFRA.TFSTATE.STATE · CI/CD: GitHub Actions (ci, build-image, deploy, backfill)
```

**Why "Snowflake-only".** We did not add a separate cloud provider. Snowflake itself runs on **Google Cloud (europe-west2)**, and its internal stages are cloud object storage, encrypted and managed. The only thing that must run outside Snowflake is calling external APIs (trial accounts cannot open network access). That job runs in a **container on GitHub Actions**: managed, ephemeral, logged, and free for our volume. There is no VM, no bucket and no scheduler to operate, and the whole platform lives in one place.

## 2. Sources (5 real + 1 real reference + 6 simulated internal systems)

| # | Source | Real? | Format / volume | What it brings to the decision |
|---|---|---|---|---|
| S1 | **Open-Meteo archive** (ERA5) | REAL, no key | JSON, 12 apiaries × daily since 2021 (~25 k rows) | foraging days → flow index |
| S2 | **Open-Meteo forecast** | REAL, no key | JSON, 12 × 8 days | foraging days forecast (dashboard) |
| S3 | **Frankfurter = ECB reference rates** | REAL, no key | JSON, EUR→HUF/RON/USD/PLN, working days | converts HU/RO partner prices to EUR |
| S4 | **GBIF occurrence API** | REAL, no key | JSON facets, 8 plants × 3 countries × month | bloom intensity vs prior years |
| S5 | **Eurostat Comext DS-045409** (HS 0409 honey) | REAL | SDMX API (CSV), monthly, EU27 imports from 9 extra-EU origins | spot import price €/kg |
| S6 | **FranceAgriMer Observatoire 2024** | REAL | 8 bulk prices, transcribed to a dbt seed | price per variety, variety premium |
| S7 | ERP order lines | simulated | JSONL, changed rows/day, 16 k rows | demand (B2B + B2C) |
| S8 | ERP customers | simulated | CSV, weekly snapshot | dimension |
| S9 | Beekeeper portal (master + harvest declarations) | simulated, **PII** | CSV | expected intake, reliability |
| S10 | LIMS (2 labs) | simulated | CSV per lab per day | lot release, pass rate |
| S11 | WMS stock | simulated | CSV full daily snapshot, **333 k rows** | stock position |
| S12 | IoT hive scales (24 hives) | simulated | JSON events every 4 h, **151 k events** | hive weight gain → flow index |

The simulated sources come from `data_generator/generate.py` (seed 42). It reproduces the assumptions of doc 01 **and the defects of real systems**: 16 kinds of injected issues (mixed date formats, French decimal commas, a variety spelled 20 ways, epoch timestamps, renamed JSON keys, 0 kg sensor readings, duplicates, schema drift). Every injected issue is counted in `answer_key.json`.

## 3. Ingestion methods: "requirement → method → why not the others"

| Arrow | Method | Requirement | Why this method | Why not… |
|---|---|---|---|---|
| APIs → stage | **API pull, incremental watermark** (container on GitHub Actions; watermark files in `@OPS.EXTRACT_STATE`) | complete days, daily | only new days are fetched; ERA5 is re-read with a 7-day overlap because it is revised, and silver keeps the latest extraction per day | Snowflake external access: not available on trial accounts, and a raw copy in the stage is replayable |
| ERP / WMS / portal → stage | **Daily batch files** (changed rows / snapshot), `PUT … OVERWRITE=TRUE` | decision is daily | simplest and cheapest; a rerun of the same day replaces the same file | CDC (Openflow, Debezium): needs a database connector, overkill for a daily decision |
| stage → BRONZE (ERP, WMS, APIs) | **COPY INTO**, run by the task graph at 06:30 | load right before dbt | Snowflake remembers loaded files for 64 days, so a retry never loads a file twice (idempotent) | Snowpipe: would load at random times, while dbt needs them all at 06:30 |
| Labs → BRONZE | **Snowpipe** (serverless micro-batch): the producer triggers the pipe right after the upload (`ALTER PIPE … REFRESH PREFIX`) | files arrive during the day | loaded within ~1 min, billed per file, no warehouse | a 06:30 batch would delay the lot releases the quality manager needs |
| Hive scales → BRONZE | **Micro-batch every 4 h + Snowpipe** (devices report every 4 h) | readings every 4 h | latency matches the device rhythm; a separate alert watches the feed | Kafka / Snowpipe Streaming: needs an always-on client, too heavy for 24 devices and a weekly decision |
| BRONZE → SILVER | **Incremental MERGE** (dbt incremental, `_loaded_at` watermark, `unique_key`) on ERP lines, WMS snapshots and hive events | big tables keep growing | only new rows are processed; a replay or a duplicate cannot double count | full refresh: reprocesses ~500 k rows every day for nothing |
| Eurostat | **API pull, full refresh of 36 months** (SDMX-CSV), on the 1st and 15th, tolerant to outages | published monthly, ~45 days of lag, recent months revised | replacing the window absorbs Eurostat's revisions; an outage keeps the last value | a daily pull (useless), a manual download (forgotten) |
| FranceAgriMer | **dbt seed** (CSV in Git) | yearly report, 8 numbers | versioned, reviewed in a pull request, cited | scraping a PDF |
| Streamlit → GOLD | **SQL INSERT** (decision log) | the decision must be recorded | closes the loop decision → action → measured outcome | a form in another tool |

Every bronze table carries `_source_file`, `_file_row_number` and `_loaded_at`, which make replay, debugging and freshness checks possible. `SELECT * FROM DIRECTORY(@BEEGS.OPS.LANDING)` lists every landed file.

## 4. Transformation: dbt (mandatory), 3 layers

| Layer | Schema | Models | Rules |
|---|---|---|---|
| Bronze | `BRONZE` | 12 raw tables (VARIANT for JSON, VARCHAR for CSV) | loaded as-is, never modified |
| Silver | `SILVER` | 12 `stg_*` (typing, cleaning, dedup, `reject_reason`) + `quarantine` + 12 `int_*` (business logic, as-of logic) | nothing is dropped silently: a bad row goes to `QUARANTINE` with its reason |
| Gold | `GOLD` | `gold_supply_coverage_weekly`, `gold_coverage_actions`, `fct_service_level_monthly`, `fct_order_lines`, `dim_*`, `gold_apiary_signals`, `gold_pipeline_health` | consumed by the dashboard, the alerts and the analysts; SELECT granted by dbt to the consumer roles |

**Tests (79 in one `dbt build`):** keys (`unique`, `not_null`, `unique_combination`), relationships, accepted values, business rules (EU limits on lab results, reconciliation with the WMS, horizon completeness), a quarantine-share test **upstream** of gold (a broken file makes the build skip gold), source freshness, and a **unit test** of the metric formula.

**As-of logic:** every intermediate model reads the version of the data *known on the decision date*, so any past Monday can be replayed (backtest). The gold table is merged on `as_of_date`, so a replay never double counts.

**Where dbt runs:** as a **dbt Project on Snowflake** (`BEEGS.OPS.BEEGS_DBT`), deployed by CI with `snow dbt deploy` and executed by the task graph. The same code runs locally on DuckDB (`scripts/local_load_duckdb.py`, cross-database macros in `macros/cross_db.sql`) and in CI on every pull request.

## 5. Tool choices and trade-offs (C4)

| Need | Choice | Credible alternative | Trade-off / why our choice |
|---|---|---|---|
| Warehouse + storage | **Snowflake** (Enterprise trial, hosted on **Google Cloud europe-west2**) | BigQuery | Course tool. Internal stages, Snowpipe, tasks, masking policies, data metric functions, budgets, Streamlit and dbt projects all sit in one platform, so the demo happens "only in Snowflake" as required. BigQuery is cheaper at rest, but scheduling, masking and the app would need 3 more services. |
| Landing zone | **Internal stage** `@OPS.LANDING` (server-side encrypted, directory table) | a cloud bucket (GCS/S3) | No extra account, IAM or notification plumbing, and the raw files stay next to the data. At a few GB and one consumer, an external bucket brings nothing. It becomes worth it when a second engine has to read the files (Iceberg tables, roadmap). |
| Extraction compute + schedule | **GitHub Actions** running our **Docker image** (GHCR, version tags) | Cloud Run Jobs + Cloud Scheduler; Snowpark Container Services | Managed and ephemeral; retries, logs and history built in; free for our volume (~6 h/month). The code and its schedule live in the same repository. Limit: GitHub cron can be delayed by a few minutes, which is fine for a daily decision. |
| Transformation | **dbt Core as a dbt Project on Snowflake** (2025 feature) | dbt Cloud; dbt Core in a container; SQLMesh | Runs inside the warehouse: no runner and no password. Versions and run history are visible in Snowsight. Fallback: the same project runs in a container. |
| Orchestration | **Snowflake task graph** (+ GitHub cron for extraction only) | **Airflow** (Cloud Composer / Astronomer) | Our 4 transformation steps are SQL inside Snowflake. Tasks give retries, a finalizer, a graph UI and history at ~€0, with no laptop that must stay on. Composer costs ~€300+/month for a prototype; Airflow becomes worth it when we orchestrate many systems outside Snowflake. |
| IaC | **OpenTofu** (open-source Terraform, Linux Foundation) + `snowflakedb/snowflake` provider ~> 2.1; **state encrypted client-side (AES-GCM)** and stored in a Snowflake stage | Terraform + HCP Terraform; Pulumi | Same HCL as Terraform. OpenTofu adds **native state encryption**, so the state can live in our own stage without a third-party backend. CI concurrency acts as the lock. |
| CI/CD | **GitHub Actions**: `ci` (DuckDB build + 79 tests + reconciliation, `tofu validate`, docker build), `deploy` (tofu apply → SQL → dbt deploy), `build-image` | GitLab CI; manual deployment | Every change is tested before it reaches Snowflake, and the deployment is reproducible from Git alone. |
| Quality | dbt tests + unit test + **Data Metric Functions** + **serverless alerts** | Great Expectations, Soda, elementary | dbt tests stop bad data before gold; DMFs watch the micro-batch tables between dbt runs. No extra tool. |
| Dashboard | **Streamlit in Snowflake** | Power BI, Looker Studio, Metabase | Next to the data, same roles, can **write** the decision back (INSERT), no extract to refresh. |
| Secrets | **Key-pair** service users (`TYPE = SERVICE`, no password) + GitHub encrypted secrets | passwords in a `.env` file | Nothing secret in the code, the image or the state. Keys can be rotated with `ALTER USER … SET RSA_PUBLIC_KEY_2`. |

**What we deliberately did NOT add (no decorative components):** a separate cloud bucket, Kafka, Spark, Kubernetes, Airflow, a data catalog, Iceberg. Each solves a problem we do not have at 250 k rows/day. Each is on the roadmap with the trigger that would justify it.

**Recent tools we use, and why:** dbt Projects on Snowflake (2025), dbt unit tests (1.8+), OpenTofu state encryption (1.7+), Snowflake Data Metric Functions, serverless alerts and Budgets, task graph finalizers, `TYPE = SERVICE` users, Snowflake CLI 3 (`snow dbt deploy`), DuckDB for free local development.

## 6. Cloud use is real and controlled (C5)

- **Storage actually traversed:** every source lands in `@BEEGS.OPS.LANDING/<source>/…` before bronze (`_source_file` in any bronze table, `DIRECTORY(@LANDING)`).
- **Cloud-executed processing with run evidence:**
  - GitHub Actions runs of `extract-daily` / `hive-readings` (logs, duration, status);
  - Snowflake task history (`OPS.PIPELINE_RUN_LOG`, Snowsight → Transformation → Tasks);
  - dbt project runs (Snowsight → Transformation → dbt projects);
  - Snowpipe `COPY_HISTORY`.
- **IaC with protected state:** `terraform/snowflake` declares the warehouses, the database, 4 schemas, 3 functional roles and the role hierarchy, plus ~20 grants. The state is encrypted (AES-GCM, enforced) and stored in `@BEEGS_INFRA.TFSTATE.STATE` (BEEGS_ADMIN only); the CI concurrency group acts as the lock. The only manual step is `snowflake/00_bootstrap_accountadmin.sql` (what needs ACCOUNTADMIN).
