"""
Run the 2 incident scenarios on the LOCAL DuckDB copy and print the evidence (docs/evidence/incident_tests_local.txt).
  INC-001  replay: the same ERP file is loaded a 2nd time (forced reload) -> no double counting in silver / gold
  INC-002  schema drift in a lab file -> rows quarantined -> upstream test fails -> gold NOT refreshed -> fix -> recovery
The same scenarios are run on Snowflake with snowflake/incidents/*.sql.
"""
import csv, datetime as dt, subprocess, sys
from pathlib import Path
import duckdb

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "data" / "beegs_local.duckdb"
DBT = ["dbt", "--no-use-colors", "build", "--profiles-dir", "../profiles_local", "-q"]


def q(sql):
    con = duckdb.connect(str(DB)); r = con.sql(sql).fetchall(); con.close(); return r


def dbt(args=()):
    p = subprocess.run(DBT + list(args), cwd=ROOT / "dbt" / "beegs", capture_output=True, text=True)
    lines = [l for l in p.stdout.splitlines() if "ERROR" in l or "FAIL" in l or "SKIP" in l or "Done." in l]
    return p.returncode, lines


def snapshot(label):
    s = {
        "bronze_erp_rows": q("select count(*) from bronze.ERP_ORDER_LINES_RAW")[0][0],
        "silver_versions": q("select count(*) from silver.stg_erp__order_lines")[0][0],
        "open_b2b_kg": q("select round(sum(quantity_kg),1) from silver.int_order_lines_asof where channel='B2B' and status='CONFIRMED'")[0][0],
        "gold_rows_latest": q("select count(*) from gold.gold_supply_coverage_weekly where as_of_date=(select max(as_of_date) from gold.gold_supply_coverage_weekly)")[0][0],
        "gold_cum_demand_acacia_w8": q("select cumulative_demand_kg from gold.gold_supply_coverage_weekly where variety_code='ACACIA' and week_number=8 and as_of_date=(select max(as_of_date) from gold.gold_supply_coverage_weekly)")[0][0],
        "gold_computed_at": str(q("select max(computed_at) from gold.gold_supply_coverage_weekly")[0][0]),
    }
    print(f"  [{label}] " + ", ".join(f"{k}={v}" for k, v in s.items()))
    return s


print("=== INC-001  Replay of an already-loaded ERP file (forced reload) ===")
before = snapshot("before")
con = duckdb.connect(str(DB))
f = sorted((ROOT / "data/landing/erp_order_lines").rglob("*.jsonl"))[-1]
n = 0
for i, line in enumerate(f.read_text().splitlines(), 1):
    con.execute("insert into bronze.ERP_ORDER_LINES_RAW values (?, ?, ?, now())", [line, f"landing/{f.relative_to(ROOT / 'data/landing').as_posix()}", i]); n += 1
con.close()
print(f"  reloaded {f.name}: {n} rows inserted AGAIN in bronze")
rc, lines = dbt()
print("  dbt build:", lines[-1] if lines else rc)
after = snapshot("after ")
ok = all(before[k] == after[k] for k in ("silver_versions", "open_b2b_kg", "gold_rows_latest", "gold_cum_demand_acacia_w8"))
print(f"  RESULT: bronze +{after['bronze_erp_rows'] - before['bronze_erp_rows']} rows, silver/gold unchanged -> {'PASS (no double counting)' if ok else 'FAIL'}\n")

print("=== INC-002  Lab export changed its columns (schema drift) ===")
before = snapshot("before")
bad = ROOT / "incidents" / "lab_results_lab_apinov_BROKEN.csv"
con = duckdb.connect(str(DB))
with open(bad, newline="") as fh:
    rows = list(csv.DictReader(fh))
for i, r in enumerate(rows, 1):   # load by column NAME like Snowpipe MATCH_BY_COLUMN_NAME: renamed columns arrive as NULL
    con.execute("insert into bronze.LAB_RESULTS_RAW values (?,?,?,?,?,?,?,?,?,?,?,?, now() + interval 1 day)",
                [r["sample_id"], r["lot_id"], r["lab_name"], r["analysis_date"], r["declared_variety"], r.get("moisture_pct"),
                 r["hmf_mg_kg"], r["pollen_origin_match"], r["c4_sugar_pct"], r.get("verdict"), "landing/lab_results/dt=2026-10-31/" + bad.name, i])
con.close()
print(f"  loaded {bad.name}: {len(rows)} rows, columns 'moisture'/'result' unknown -> moisture_pct & verdict NULL")
rc, lines = dbt()
print("  dbt build exit code:", rc)
for l in lines[:6]:
    print("   ", l.strip()[:150])
after = snapshot("after ")
print(f"  RESULT: build failed={rc != 0}, gold refreshed={before['gold_computed_at'] != after['gold_computed_at']} -> "
      f"{'PASS (bad data stopped before gold)' if rc != 0 and before['gold_computed_at'] == after['gold_computed_at'] else 'FAIL'}")
print("  quarantine:", q("select reject_reason, count(*) from silver.quarantine where source_name='lab_results' group by 1"))

print("\n  RECOVERY: the lab re-sends the file with the agreed columns -> latest load per sample_id wins")
con = duckdb.connect(str(DB))
for i, r in enumerate(rows, 1):
    con.execute("insert into bronze.LAB_RESULTS_RAW values (?,?,?,?,?,?,?,?,?,?,?,?, now() + interval 2 day)",
                [r["sample_id"], r["lot_id"], r["lab_name"], r["analysis_date"], r["declared_variety"], r["moisture"],
                 r["hmf_mg_kg"], r["pollen_origin_match"], r["c4_sugar_pct"], r["result"], "landing/lab_results/dt=2026-10-31/lab_results_lab_apinov_20261031_v2.csv", i])
con.close()
rc, lines = dbt()
print("  dbt build:", lines[-1] if lines else rc)
snapshot("recovered")
print("  quarantine now:", q("select count(*) from silver.quarantine where source_name='lab_results'"))
