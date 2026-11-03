# 06 · Reliability: checks, incidents and recovery

> Criterion C6: key, business-rule and freshness/completeness checks with a demonstrated failure; replay without double counting; scheduling, logs, and two incident scenarios, one of them tested.

## 1. Checks in place

| Type | Check | Where | On failure |
|---|---|---|---|
| **Key** | `unique` / `not_null` on every business key; `unique_combination` on composite grains (gold: as_of × variety × week) | dbt | build fails, downstream skipped |
| **Key** | dedup on `event_id` (gateway retries, re-sent files), on `order_line_version_key`, on `(snapshot_date, lot_id)` | dbt silver | duplicates removed (1,509 hive duplicates = all injected ones) |
| **Business rule** | lab PASS must respect the EU limits (moisture ≤ 20 %, HMF ≤ 40) | `assert_lab_pass_respects_eu_limits` | warn → quality manager |
| **Business rule** | released stock in GOLD = Σ RELEASED lots in WMS (to the kg) | `assert_released_stock_reconciles_with_wms` | build fails |
| **Business rule** | the metric formula on a hand-computed case | unit test `coverage_formula_acceptance_test` | build fails |
| **Completeness** | today's ERP and WMS exports present in bronze (WMS ≥ 50 lots) | task `T_CHECK_COMPLETE` | graph stops, dbt not run, e-mail |
| **Completeness** | 64 rows (8 varieties × 8 weeks) in the latest decision | `assert_horizon_is_complete` | build fails |
| **Quality share** | > 5 % rejected rows among the last 3 days of loads of a source | `recent_reject_share` on 5 staging models (**upstream** of gold) | build fails, gold not refreshed |
| **Freshness** | `dbt source freshness` (26 h warn / 50 h error for daily sources, 6 h / 24 h for hive scales), declared but not run by the daily pipeline | `_sources.yml` | warn / error |
| **Freshness (streaming)** | no hive event for 6 h | serverless alert `A_HIVE_FEED_STALE` (every 2 h) + DMF FRESHNESS | e-mail to the data team |

## 2. INC-001: replay of an already-loaded file (no double counting). TESTED

**Scenario.** The ERP export of a day is loaded a second time. This happens after a manual `COPY … FORCE = TRUE` during an investigation, or when the ERP re-uploads the same file under a new name. A naive pipeline would double the demand and turn GREEN varieties RED.

**Expected behaviour.** Bronze gets the duplicate rows (bronze is the history of what was received), but silver and gold stay identical.

**Test** (`scripts/local_incident_test.py`; on Snowflake `snowflake/incidents/inc001_replay.sql`):

```
[before] bronze_erp_rows=16510, silver_versions=16510, open_b2b_kg=26700.0, gold_rows_latest=64, gold_cum_demand_acacia_w8=6785.7
reloaded erp_order_lines_20261101.jsonl: 14 rows inserted AGAIN in bronze
[after ] bronze_erp_rows=16524, silver_versions=16510, open_b2b_kg=26700.0, gold_rows_latest=64, gold_cum_demand_acacia_w8=6785.7
RESULT: bronze +14 rows, silver/gold unchanged -> PASS (no double counting)
```

**Why it works.** `stg_erp__order_lines` is incremental and MERGEs on `order_line_id|updated_at`. Inside a batch, `QUALIFY ROW_NUMBER()` keeps one copy. `gold_supply_coverage_weekly` MERGEs on `(as_of_date, variety_code, week_number)`.

## 3. INC-002: a lab changes its export format (schema drift). TESTED, failure demonstrated

**Scenario.** Lab APINOV switches LIMS software. Its CSV now has `moisture` instead of `moisture_pct` and `result` instead of `verdict`. Snowpipe loads by column name (`MATCH_BY_COLUMN_NAME`), so the load succeeds, but both columns arrive **NULL**. If nothing stopped it, 60 lots would have no verdict and the pass rate would be wrong.

**Detection and containment** (test output, `docs/evidence/incident_tests_local.txt`):

```
loaded lab_results_lab_apinov_BROKEN.csv: 60 rows, columns 'moisture'/'result' unknown -> moisture_pct & verdict NULL
dbt build exit code: 1
  FAIL 2 recent_reject_share_stg_lims__lab_results_3__0_05
RESULT: build failed=True, gold refreshed=False -> PASS (bad data stopped before gold)
```

1. In silver, the 60 rows get `reject_reason = 'unknown_verdict'`.
2. The upstream test `recent_reject_share` fails: the file is 100 % rejected (per-file threshold 50 %), and the recent share is above 5 %.
3. `dbt build` **skips every model downstream**: gold keeps yesterday's correct figures (`computed_at` unchanged).
4. Task `T_DBT_BUILD` fails → the finalizer writes `FAILED` in `OPS.PIPELINE_RUN_LOG` and e-mails the data team.

**Recovery (tested).** The quality manager asks the lab to re-send the file with the agreed columns, or we add the new column names to the mapping. The corrected file is loaded; silver keeps the **latest load per `sample_id`**; `EXECUTE TASK T_ROOT` → build green, gold refreshed, quarantine back to 0.

**Prevention.** The column contract is written in the lab agreement. The DMF `NULL_COUNT` on `LAB_RESULTS_RAW` sees it within minutes, not the next morning.

## 4. INC-003: the hive scale feed goes silent. Documented, not tested

**Scenario.** The 4G gateway of an apiary is down, the `hive-readings` workflow is disabled or failing, or the pipe is paused.

**Detection.** Serverless alert `A_HIVE_FEED_STALE` (no row for 6 h, checked every 2 h).

**Impact.** Limited by design: the flow factor falls back to the other signals (missing ratio = neutral 1.0), so the decision is degraded, not wrong.

**Recovery.**
1. `SELECT SYSTEM$PIPE_STATUS('BEEGS.OPS.PIPE_HIVE_EVENTS');`
2. GitHub → Actions → hive-readings: last runs and their logs.
3. Re-run the workflow for the missing windows; duplicates are removed on `event_id`.
4. `ALTER PIPE … REFRESH` for the files written meanwhile.

## 5. INC-004: an external API is down. It REALLY happened (2 November 2026)

**What happened.** During our initial load, the Open-Meteo archive API answered HTTP 503, then timed out, for several hours. The first version of the extract job ran the sources one after the other and stopped at the first exception: **the whole backfill failed**, although the 6 other sources were fine (GitHub Actions runs of the `backfill` workflow, 2 Nov).

**Fix (commit "isolate each external API").**
- Each external source runs in isolation: a failure is logged as `{"source": ..., "status": "failed"}`, the other sources and the internal files still land.
- The `apis` task still exits non-zero at the end, so the run is red and the repository owner is e-mailed: the outage is visible, not hidden.
- In `extract-daily`, the internal files are extracted even if `apis` failed (they feed the completeness gate).
- The source keeps no new watermark, so the next run catches up exactly what was missed (for the weather history: everything since 2021, in yearly chunks).

**Impact on the decision.** None on the critical path: the completeness gate only needs the ERP and WMS files, so the task graph ran and the decision was produced. The weather signal is missing until the API is back (the flow factor falls back to neutral), which is visible in `GOLD_PIPELINE_HEALTH` and in the cockpit.

**Lesson.** We had written this incident as "behaviour by design" before it happened. The real outage showed that the design was incomplete: one external dependency could block everything. See docs/10.
