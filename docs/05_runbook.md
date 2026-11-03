# 05 · Runbook: launch, operate, replay, shut down

> Criteria C3 (documented launch, reproducible code, containerised job), C6 (scheduling, logs, replay), C7 (shutdown procedure).

## 0. What you need

| | |
|---|---|
| Snowflake account (trial is fine), Enterprise edition | ours: `ZEFQCKT-WL69349`, Google Cloud europe-west2 |
| GitHub repository with Actions enabled | `Philomenechlt/beegs_data_pipeline` |
| For local development only | Python 3.12 + `pip install dbt-duckdb duckdb pandas` |

## 1. Local run (free, 2 minutes, no cloud)

```bash
python data_generator/generate.py --out data/landing --end 2026-11-01      # internal systems (seed 42)
python data_generator/local_fixtures.py --out data/landing                 # API-shaped fixtures (LOCAL ONLY)
python scripts/local_load_duckdb.py                                         # = Snowflake bronze, in DuckDB
cd dbt/beegs && dbt build --profiles-dir ../profiles_local                  # 117 nodes, all green
python ../../scripts/verify_against_answer_key.py                          # reconciliation with the truth
```

## 2. Cloud deployment (first time, ~20 min, almost everything automated)

**Manual steps (the only ones):**

1. **Generate 2 key pairs** (one per service user), on any machine with OpenSSL:
   ```bash
   openssl genrsa 2048 | openssl pkcs8 -topk8 -nocrypt -out deploy.p8 && openssl rsa -in deploy.p8 -pubout -out deploy.pub
   openssl genrsa 2048 | openssl pkcs8 -topk8 -nocrypt -out pipeline.p8 && openssl rsa -in pipeline.p8 -pubout -out pipeline.pub
   ```
2. **Snowsight, as ACCOUNTADMIN:** open `snowflake/00_bootstrap_accountadmin.sql`, paste the 2 public keys (the lines between BEGIN and END), then **Run All**. This creates the role `BEEGS_ADMIN`, the 2 service users, the state database `BEEGS_INFRA`, the resource monitor and the e-mail integration.
3. **GitHub → Settings → Secrets and variables → Actions:** add `SNOWFLAKE_DEPLOY_PRIVATE_KEY`, `SNOWFLAKE_PIPELINE_PRIVATE_KEY` (full PEM blocks) and `TF_STATE_PASSPHRASE` (≥ 16 characters). Then delete the `.p8` files.

**Automated (GitHub Actions):**

4. **`build-image`** (on push): builds `ghcr.io/<owner>/beegs-extract:1.0.<run>` and `:stable`.
5. **`deploy`** (on push, or Actions → deploy → *Run workflow*):
   1. OpenTofu `plan` → `apply`: warehouses, database, schemas, roles, grants. The state is downloaded from and uploaded to `@BEEGS_INFRA.TFSTATE.STATE`, encrypted.
   2. SQL `01` stages, `02` bronze tables + pipes + load procedure, `05` masking + decision log, `07` tags + GDPR task, `08` budget + FinOps views.
   3. `snow dbt deploy BEEGS_DBT`, which creates a new version of the dbt project object.
   4. SQL `03` task graph (+ `04` alerts once GOLD exists).
6. **`backfill`** (Actions → backfill → *Run workflow*, once): lands the history (2024-01-01 → yesterday) and the real API history, then:
   1. `CALL SP_LOAD_BATCH(NULL)`;
   2. first `dbt build`;
   3. the backtest of 2026-03-30;
   4. alerts and DMFs.
7. Attach the resource monitor, **as ACCOUNTADMIN**: `ALTER WAREHOUSE BEEGS_PIPELINE_WH SET RESOURCE_MONITOR = BEEGS_MONTHLY_RM;` (same for `BEEGS_BI_WH`).
8. **Streamlit:** Snowsight → Projects → Streamlit → *+ Streamlit App* in `BEEGS.GOLD`, warehouse `BEEGS_BI_WH`. Paste `streamlit/coverage_app.py` and share the app with the role `BEEGS_PURCHASING`.

## 3. Daily operations (automatic)

| Time (Paris) | What | Where to look |
|---|---|---|
| 04:17 (fallback 05:47) | GitHub Actions `extract-daily`: container runs `internal` then `apis` → PUT to `@OPS.LANDING`, then Snowpipe for lab files | GitHub → Actions → extract-daily (logs, duration) |
| every 4 h (:17) | `hive-readings`: last 4 h of readings → stage → Snowpipe | Actions → hive-readings; `SELECT SYSTEM$PIPE_STATUS('BEEGS.OPS.PIPE_HIVE_EVENTS');` |
| 06:30 | task graph T_ROOT → LOAD_BATCH → CHECK_COMPLETE → DBT_BUILD → FINALIZER | Snowsight → Monitoring → Task history (graph); `SELECT * FROM BEEGS.OPS.PIPELINE_RUN_LOG ORDER BY finished_at DESC;` |
| 07:30 | alert A_COVERAGE_RED → Head of Sourcing | `ALERT_HISTORY` |
| every 2 h | alert A_HIVE_FEED_STALE → data team | `ALERT_HISTORY` |
| continuous | Budget forecast + resource monitor | Snowsight → Admin → Cost management |

**Retries:**
- Extraction: 2 attempts per task (internal files first, 20 min cap each), plus a fallback run at 05:47 if the 04:17 run did not succeed (GitHub can skip scheduled runs).
- If the morning run still failed because files were missing: Actions → `extract-daily` → *Run workflow*, then Actions → `run-pipeline`.
- Task graph: `TASK_AUTO_RETRY_ATTEMPTS = 2`, and the graph is suspended after 3 failed days in a row, so it cannot loop silently.
- A failed GitHub workflow e-mails the repository owner.

Every retry is safe because each step is idempotent (§4).

## 4. Replay and backfill without double counting

| Situation | Command | Why it does not double count |
|---|---|---|
| Re-extract a day | Actions → extract-daily → *Run workflow* with `run_date = 2026-10-31` | `PUT … OVERWRITE=TRUE`: same file name, same object |
| Re-run the whole graph | `EXECUTE TASK BEEGS.OPS.T_ROOT;` | COPY skips files already loaded; dbt incremental models MERGE on keys; gold merges on `as_of_date` |
| A source re-sends a corrected file | upload it → COPY/Snowpipe loads it | silver keeps the **latest `_loaded_at`** per business key |
| Reload a day from scratch | `COPY INTO … PATTERN='.*dt=2026-10-31/.*' FORCE = TRUE` then the dbt build | bronze gets duplicates; silver dedups (tested: INC-001) |
| Replay a past decision | `EXECUTE DBT PROJECT BEEGS.OPS.BEEGS_DBT ARGS = $$build --select +gold_supply_coverage_weekly --vars '{as_of_date: 2026-03-30}'$$;` | as-of logic + merge on `as_of_date` |
| Rebuild everything | `ARGS = 'build --full-refresh'` | bronze is the source of truth |
| Undo a bad load in bronze | `CREATE TABLE … CLONE … AT(OFFSET => -3600)` (Time Travel, 7 days on BRONZE) | |

## 5. Shutdown and cleanup procedure (after the defence)

1. **Stop the schedules:**
   - GitHub → Actions → `extract-daily` and `hive-readings` → *Disable workflow*;
   - in Snowflake: `ALTER TASK BEEGS.OPS.T_ROOT SUSPEND;`, suspend both alerts, pause both pipes (`snowflake/06_costs_and_teardown.sql §2a`).
2. **Export what we keep:** download the `GOLD` tables as CSV (Snowsight) for the report.
3. **Infrastructure:** `tofu destroy` from the deploy workflow (or locally with the same secrets) drops the warehouses, the database, the schemas, the roles and the grants.
4. **Manual objects, as ACCOUNTADMIN:** follow `06_costs_and_teardown.sql §2c-d`, i.e. the integration, the monitor, the 2 service users, `BEEGS_INFRA` and `BEEGS_ADMIN`.
5. **GitHub:** delete the 3 secrets and the GHCR package.
6. **One week later:** Snowsight → Admin → Cost management shows 0 credits for BEEGS warehouses.

## 6. Moving the project to a new GitHub repository

The code has no hard-coded repository name (the container image is `ghcr.io/<owner>/beegs-extract`). To run it from a new repository:

1. Push the code (keep `.github/workflows/`).
2. Settings → Secrets and variables → Actions: create the 3 secrets `SNOWFLAKE_DEPLOY_PRIVATE_KEY`, `SNOWFLAKE_PIPELINE_PRIVATE_KEY`, `TF_STATE_PASSPHRASE` (same values as in the old repository; the Snowflake account does not change).
3. Settings → Actions → General: allow GitHub Actions; workflow permissions "Read and write" (to push the image to GHCR).
4. Run `build-image` once (it creates `ghcr.io/<new owner>/beegs-extract:stable`), then `ci`, then `deploy` (it should show "No changes" for OpenTofu).
5. Run `health-check`: the last line of `PIPELINE_RUN_LOG` must be `SUCCESS`. If not: `extract-daily`, then `run-pipeline`.
6. Disable the schedules (`extract-daily`, `hive-readings`) in the **old** repository, so that the two repositories do not extract the same day twice.
7. Replace the repository URL in this runbook (§0), on the thank-you slide and in `docs/08_team_and_demo.md` if it appears there.
