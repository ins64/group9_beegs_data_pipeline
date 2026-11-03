# 08 · Team ownership and defence script (15-20 min)

> Criterion C8: clear storyline, readable architecture, claims tied to evidence, explicit limitations, time management and coordination. The brief requires that **every person owns a part of the pipeline**.

## 1. Who owns what

| Person | Owns on the pipeline | Files | Presents (slides) |
|---|---|---|---|
| **Kelsy NGUYEN** | **Business case, use case & metric, sources and extraction** (real APIs, extract container, simulator of the internal systems) | `docs/01-02`, `extract/`, `data_generator/`, `config/` | BeeG's, business model, problem, decision & metric, sources |
| **Philomène CHOLET** | **Ingestion and orchestration** (landing stage, COPY INTO, Snowpipe, task graph), **reliability and incidents**, **live demo** | `snowflake/01-03`, `snowflake/incidents/`, `incidents/`, `docs/05-06`, `docs/11` | architecture, ingestion, tools, reliability, **LIVE DEMO** |
| **Inès SIMOND-CHARBINAT** | **dbt transformations**: bronze → silver → gold, 117 tests + unit test, lineage, Streamlit cockpit, validation (reconciliation, backtest) | `dbt/beegs/`, `streamlit/`, `scripts/verify_against_answer_key.py`, `docs/04` | dbt layers & tests, cockpit, "is the number right?" |
| **Alzira FERREIRA** | **FinOps & TCO**, plus the platform around it: IaC (OpenTofu) & CI/CD, security & governance, lessons learned | `terraform/snowflake/`, `.github/workflows/`, `snowflake/00, 04-08`, `docs/07, 09, 10` | IaC & CI/CD, security & governance, FinOps & TCO, what did not work, limits |

## 2. Storyline and timing (19 min + Q&A)

| # | Start | Who | Slide / demo | Key sentence | Evidence shown |
|---|---|---|---|---|---|
| 1-2 | 0:00 | Kelsy | Title + who owns what | "Four of us, one pipeline, one owner per part." | – |
| 3-4 | 0:30 | Kelsy | BeeG's in one minute + business model | "We sell honey all year round, but bees make it once a year." 60 beekeepers, 110 B2B customers, €1.7 M | doc 01 |
| 5 | 1:30 | Kelsy | The problem | "In 2025 we failed to deliver 1 kg out of 6: €294 k." | `FCT_SERVICE_LEVEL_MONTHLY` |
| 6 | 2:15 | Kelsy | Decision + metric | Head of Sourcing, every Monday; coverage ratio; RED < 0.9 | doc 02 |
| 7 | 3:15 | Kelsy | Sources | "Each source answers one part of the formula." | doc 03 §2 |
| 8 | 4:00 | Philomène | Architecture | Read it left → right, one arrow = one method | diagram |
| 9-10 | 5:00 | Philomène | Ingestion methods + tools & trade-offs | requirement → method → why not the others; why no Airflow, why Snowflake only | doc 03 §3, §5 |
| 11 | 6:30 | Inès | dbt: 3 layers, 117 tests | "Nothing is dropped silently: quarantine." | dbt DAG |
| 12 | 7:45 | Inès | Cockpit | "ACACIA RED from W48, 3.5 t short → buy partner stock" | heatmap |
| 13 | 8:45 | Inès | Is the number right? | unit test + reconciliation to the kg + backtest | evidence files |
| 14 | 9:30 | Philomène | Reliability | idempotent steps, completeness gate, finalizer, real Open-Meteo outage | doc 06 |
| 15 | 10:00 | Philomène | **LIVE DEMO (5 min)** | landed data → incident injected → task graph fails safely → cockpit | **docs/11_live_demo.md** |
| 16 | 15:00 | Alzira | IaC & CI/CD | one manual script, everything else from GitHub Actions; encrypted state | GitHub Actions |
| 17 | 15:45 | Alzira | Security & governance | roles, masking, tags, GDPR purge | doc 07, 09 |
| 18 | 16:30 | Alzira | FinOps & TCO | €15/month, €3.50 per decision, TCO vs Fivetran / Airflow | doc 09 |
| 19-20 | 17:30 | Alzira | What did not work + limits & next steps | "A green run is not a proof." | doc 10 |
| 21 | 18:45 | all | Thank you, questions | | |

**Plan B for the live part:** if Snowflake or the network fails, show the GitHub Actions run of the `incident-drill` workflow (same scenario, run on the real account, logs kept 90 days) and the evidence files in `docs/evidence/`.

## 3. Questions the panel will probably ask (and the short answer)

| Question | Answer |
|---|---|
| Why not Airflow? | 4 SQL steps inside Snowflake → task graph = no server, retries, finalizer, history. Airflow/Composer (~€300/month) when we orchestrate many external systems. |
| Why no AWS/GCP/Azure account? | Snowflake runs on Google Cloud; its stages are our object storage, and GitHub Actions is our serverless compute. A separate bucket would add an account, IAM and notifications with no benefit at our volume (doc 03 §5). |
| Why is the hive feed micro-batch and not streaming? | The scales report every 4 h and the decision is weekly; streaming would add an always-on client for no business value. |
| What if a file is loaded twice? | INC-001: COPY load metadata + MERGE on keys → silver/gold unchanged (tested). |
| How do you know the number is right? | unit test on a hand-computed case + reconciliation to the kg with the simulation truth + backtest. |
| Your internal data is fake? | Yes, simulated **on purpose** with real defects (16 kinds) and a known answer key, so we can prove the cleaning. External data is real. |
| Where are the secrets? | 2 private keys and 1 passphrase, only in GitHub encrypted secrets; service users have no password; the state is encrypted. |
| What does it cost? | ≈ €15/month (prototype) = €3.50 per weekly decision; ≈ €200/month at 10×; monitored daily (FinOps views, Snowflake Budget); capped by the resource monitor; GitHub spending limit $0. |
| Why not Fivetran? | 3-year TCO (docs/09): cheap at our MAR but no connector for our 4 APIs and no real streaming; we'd adopt it (or Openflow CDC) for the ERP/WMS once they are real databases. People cost dominates any licence. |
| What is not done? | seasonal demand baseline, calibration of the flow weights, Snowflake objects in Terraform, CI deploy. |
