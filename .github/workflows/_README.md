# GitHub Actions = the cloud compute and the CI/CD of BeeGs

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | every PR / push | generate data → DuckDB → `dbt build` (117 tests) → reconcile with answer key · `tofu fmt/validate` · docker build |
| `build-image.yml` | push to `extract/`, `data_generator/`, `config/` | builds the extract image, pushes `ghcr.io/<owner>/beegs-extract:1.0.<run>` and `:stable` |
| `deploy.yml` | push to `terraform/`, `snowflake/`, `dbt/` on main, or manual | OpenTofu plan/apply (encrypted state in a Snowflake stage) → SQL scripts 01..08 → `snow dbt deploy` |
| `extract-daily.yml` | cron 03:17 UTC (04:17 Paris) + fallback 04:47 UTC, skipped if the first run succeeded | container: REAL APIs + internal exports → PUT to `@BEEGS.OPS.LANDING` (+ Snowpipe for lab files) |
| `hive-readings.yml` | cron every 4 h | container: hive scale readings of the last 4 h → stage → Snowpipe |
| `backfill.yml` | manual | initial load of the history, first dbt build, backtest of 2026-03-30 |
| `run-pipeline.yml` | manual | runs the Snowflake task graph now (same as 06:30) and fails if the run is not `SUCCESS` |
| `health-check.yml` | manual | read-only state of the pipeline: run log, bronze volumes, gold, tasks, pipes, backtest |
| `incident-drill.yml` | manual | INC-002 on the real account, with assertions (FAILED + GOLD untouched, then SUCCESS) |
| `demo-prepare.yml` / `demo-rehearsal.yml` | manual | park the live-demo files / play the whole demo script on the real account |

Secrets (Settings → Secrets and variables → Actions): `SNOWFLAKE_DEPLOY_PRIVATE_KEY`, `SNOWFLAKE_PIPELINE_PRIVATE_KEY`,
`TF_STATE_PASSPHRASE`. Nothing else is secret; the account identifier is in the workflows.
