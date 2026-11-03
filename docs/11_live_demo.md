# 11 · Live demo (5 minutes) - step-by-step guide

> Presenter: **Philomène**. Everything runs on the real Snowflake account, in Snowsight, with your own user and the role `BEEGS_ADMIN`.
> Script: `snowflake/demo/live_demo.sql`. It was rehearsed end to end on the real account by the GitHub workflow `demo-rehearsal` (run "rehearsal1", 2 Nov 2026: broken file loaded → run FAILED in `T_DBT_BUILD` → GOLD timestamp unchanged → fixed file → run SUCCESS).

**The story in one sentence:** *"Our data lands every night. Now a lab sends a broken file, live. Watch: the pipeline refuses it, and the buyer still sees correct figures."*

---

## A. The day before (10 min)

1. **Park the demo files.** GitHub → repository → **Actions** → **demo-prepare** → *Run workflow* → keep the tag `live` → *Run workflow*.
   It must turn green. Its last step prints the health check. Look for:
   - `PIPELINE_RUN_LOG`: the last line is `SUCCESS`;
   - `GOLD_COVERAGE_ACTIONS`: ACACIA is `RED`.
2. **Rehearse once yourself, without using the `live` files:**
   - run **demo-prepare** again with the tag `rehearsal2`;
   - in your worksheet, temporarily replace `_live` with `_rehearsal2` (Ctrl/Cmd + H);
   - play steps 1-5, then the *AFTER THE DEMO* block (it puts the pipeline back to green);
   - put `_live` back.

   ⚠️ **Each tag can only be used once.** Snowpipe never loads the same file name twice.
3. **Create the worksheet.** Snowsight → *Projects* → *Worksheets* → **+** → *SQL Worksheet*. Name it `BeeGs live demo`. Paste the content of `snowflake/demo/live_demo.sql` from GitHub.
4. Increase the font size of the browser (Ctrl/Cmd + `+`, 125 %): the jury must read the results.

## B. One hour before the defence (5 min)

1. **Check last night's run.** GitHub → Actions:
   - `extract-daily` of the morning has run. If it is red only because of an external API (Open-Meteo), that is fine: the internal files are still landed;
   - the Snowflake task graph has run at 06:30. Step 1 of the script shows it.
2. **Open 3 browser tabs, in this order:**
   - **Tab A**: the worksheet `BeeGs live demo`. Top right: role **BEEGS_ADMIN**, warehouse **BEEGS_PIPELINE_WH**.
   - **Tab B**: *Monitoring* → *Task History* → click **T_ROOT** → tab **Graph** (or *Run history*).
   - **Tab C**: *Projects* → *Streamlit* → **COVERAGE_COCKPIT**. Open it once now, so it is warm.
3. In tab A, run the three `USE …` lines and the STEP 1 query once. This wakes the warehouse, so there is no cold start during the demo.

> To run one block: select its lines with the mouse, then **Ctrl + Enter** (Windows) / **Cmd + Enter** (Mac). Never use "Run all".

## C. The demo, minute by minute

| Time | Where | Do | Say |
|---|---|---|---|
| **0:00** | Tab A | Run the **STEP 1** query (rows per source). | "Every night at 4:17, our container on GitHub Actions extracts 5 real APIs and our internal systems into a Snowflake stage. Here is what landed in bronze: ERP, warehouse stock, lab results, hive scales, weather, FX, Eurostat." |
| 0:25 | Tab A | Run the `PIPELINE_RUN_LOG` query. | "At 6:30, the task graph loaded it and rebuilt our decision table. The last run is `SUCCESS`." |
| **0:45** | Tab A | Run **STEP 2**: the `COPY FILES` statement, then `ALTER PIPE … REFRESH`. | "Now an incident, live. One of our two labs changed its export: two columns are renamed. The file arrives in the lab folder, and Snowpipe, our serverless loader, is notified." |
| 1:00 | Tab A | Run the `SELECT MAX(computed_at)` query (gold timestamp). | "Let's note when our decision table was last computed: remember this time." |
| 1:15 | Tab A | Run the bronze query `… BROKEN_live …`. If it returns no row, wait 15 s and run it again. | "Snowpipe loaded the 60 rows in seconds, but the verdict and moisture columns are empty. In a naive pipeline, these lots would disappear from our supply and the buyer would panic-buy honey." |
| **1:45** | Tab A | Run **STEP 3**: `EXECUTE TASK BEEGS.OPS.T_ROOT;` Then go to **tab B** and refresh. | "Instead of waiting for tomorrow 6:30, I launch the daily pipeline now: load, completeness check, dbt build with 79 tests, and a finalizer that always logs the run." |
| **2:00** | Tab C | Show the cockpit: the KPI row, the RED line for **ACACIA**, the heatmap, the recommended action. | "While it runs, this is what the Head of Sourcing opens every Monday: ACACIA turns red in week 48, 3.5 tonnes short. Seen 4 weeks ahead, the action is to buy traceable partner stock, about €27 k, rather than a cheaper spot import. She can record her decision here, and we keep it to measure later what worked." |
| **3:30** | Tab B | Refresh. `T_LOAD_BATCH` and `T_CHECK_COMPLETE` are green, **`T_DBT_BUILD` is red**, and `T_FINALIZER` is green. | "dbt refused the data: a test checks the share of rejected rows per file. One hundred percent of this file is rejected, so the build stops before gold. The task retried once, then failed." |
| 4:00 | Tab A | Run **STEP 5**: task history, `PIPELINE_RUN_LOG` (status `FAILED`, cause `T_DBT_BUILD`), then the gold timestamp. | "The finalizer logged the failure and e-mailed the data team. And the decision table has the same timestamp as before: Monday's figures were never overwritten by bad data." |
| **4:30** | - | Conclude. | "Recovery: the lab re-sends the file in the agreed format, the next run is green. Every step is idempotent, so we can replay any day without double counting. We test this scenario automatically in a GitHub workflow." |
| 5:00 | | End. Back to the slides. | |

> **The cockpit refreshes every day, the slides do not.** The slides show the decision of Monday 1 Nov 2026 (ACACIA RED in W48, 3.5 t short). The cockpit shows the latest run, so on the day of the defence the week and the tonnage can differ slightly (on 3 Nov: W49, 3.9 t). Say it in one sentence: "The slide is Monday's decision; the cockpit is this morning's refresh."

## D. If something goes wrong (plan B)

| Problem | What to do |
|---|---|
| The bronze query returns nothing after 30 s (Snowpipe slower than usual). | Say "Snowpipe loads within about a minute", go to the cockpit (2:00), and come back to the query later. |
| `T_DBT_BUILD` is still running at 3:30. | Show the cockpit a bit longer. The full graph takes about 75 s, plus the retry of the failing task. |
| The cockpit does not open. | Run the STEP 4 query in tab A: it shows the same table. |
| Snowflake or the Wi-Fi is down. | GitHub → Actions → **demo-rehearsal** (run "rehearsal1") or **incident-drill** (run "drill4"). Open the log: the same scenario ran on the real account, with the same output. |
| You ran the demo files by mistake before the defence. | Run **demo-prepare** with a new tag (`live2`) and replace `_live` with `_live2` in the worksheet. |

## E. After the defence (2 min)

Run the block **AFTER THE DEMO** of the script:

1. it copies the fixed file into the lab folder;
2. it runs the pipeline again;
3. about 1 min 30 later, `PIPELINE_RUN_LOG` shows `SUCCESS` and GOLD has a new timestamp.

The pipeline is clean again for the next morning.
