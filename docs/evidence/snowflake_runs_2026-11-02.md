# Evidence: runs on the real Snowflake account (2 November 2026)

All runs below are GitHub Actions runs of this repository (logs kept 90 days, Actions tab). They use the deploy service user (`BEEGS_DEPLOY_SVC`, key pair) and the role `BEEGS_ADMIN`.

| What | Workflow (run) | Result |
|---|---|---|
| Initial load of the history (2024-01-01 → 2026-11-01) | `backfill` | 1,036 days of internal files landed. Bronze: 16,524 ERP lines, 348,493 WMS rows, 150,693 hive events. `dbt build`: **117/117 PASS**. The Open-Meteo archive was down (INC-004), so the other sources landed anyway. |
| Decision of 2026-11-01 | `backfill` → Evidence step | ACACIA **RED** from **2026-W48**, max shortfall **3,454.2 kg**, action **BUY FROM PARTNER STOCK** (partner option €27,385, spot option €12,977). The 7 other varieties are GREEN. Same as the local run. |
| Backtest, decision of 2026-03-30 | `backfill` (start_at = backtest) + `health-check` | GOLD holds 2 decision dates × 64 rows. **TILLEUL RED from 2026-W15**, **COLZA RED from 2026-W18**, all others not red. Same as the local reconciliation (`verification_vs_answer_key.txt`). |
| INC-002 on the real account, with assertions | `incident-drill` (tag `drill4`) | Broken lab file → Snowpipe: 60 rows, 0 verdicts → task graph: `T_DBT_BUILD` **FAILED** (reject-share test), GOLD timestamp **unchanged** → fixed file → next run **SUCCESS**, GOLD refreshed. A full graph run takes **≈ 45 s** (`T_LOAD_BATCH` 6 s, `T_CHECK_COMPLETE` 1 s, `T_DBT_BUILD` 38 s). |
| Full rehearsal of the live demo | `demo-rehearsal` (tag `rehearsal1`) | `snowflake/demo/live_demo.sql` executed statement by statement with the presenter's role and pauses: same outcome as above. |
| Cockpit | `deploy` | `BEEGS.GOLD.COVERAGE_COCKPIT` (Streamlit in Snowflake) created by CI, USAGE granted to `BEEGS_PURCHASING`. |

**Defects found by these runs and fixed the same day:** the task graph root task, the finalizer status, the Snowpipe refresh prefix in the incident script, and the quoting of the backtest vars. See `docs/10_lessons_learned.md`, items 5 and 11-13.
