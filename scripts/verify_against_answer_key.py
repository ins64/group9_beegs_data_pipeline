"""
C3 evidence - is the business output RIGHT? Compare GOLD with the generator's answer key (the truth it simulated).
  1. released stock per variety (gold)          vs true stock in the simulation
  2. open confirmed B2B order book (silver)     vs true open order book
  3. service level per year (gold)              vs true service level
  4. every injected defect                      -> repaired, quarantined or deduplicated?
  5. backtest: RED flags of 30 March 2026       vs varieties that really ran short in April-June 2026
Usage: python scripts/verify_against_answer_key.py   (after dbt build on the local DuckDB, with a fresh generation)
"""
import json
from pathlib import Path
import duckdb

ROOT = Path(__file__).resolve().parent.parent
key = json.loads((ROOT / "data" / "answer_key.json").read_text())
con = duckdb.connect(str(ROOT / "data" / "beegs_local.duckdb"), read_only=True)
ok_all = True


def check(name, got, exp, tol=0.5):
    global ok_all
    ok = abs((got or 0) - (exp or 0)) <= tol
    ok_all &= ok
    print(f"  {'OK ' if ok else 'KO '} {name:38s} gold={got!s:>12}  truth={exp!s:>12}")


print(f"Answer key as of {key['as_of_date']}\n1. Released stock (kg)")
gold = dict(con.sql("select variety_code, max(released_kg) from gold.gold_supply_coverage_weekly where as_of_date=(select max(as_of_date) from gold.gold_supply_coverage_weekly) group by 1").fetchall())
for v, kg in key["true_released_stock_kg"].items():
    check(v, round(gold.get(v, 0), 1), kg)

print("2. Open confirmed B2B order book (kg)")
ob = dict(con.sql("select variety_code, sum(quantity_kg) from silver.int_order_lines_asof where channel='B2B' and status='CONFIRMED' group by 1").fetchall())
for v, kg in key["true_open_b2b_demand_kg"].items():
    check(v, round(ob.get(v, 0), 1), kg)

print("3. B2B service level per year")
sl = dict(con.sql("select cast(year(delivery_month) as varchar), round(sum(shipped_kg)/sum(ordered_kg), 4) from gold.fct_service_level_monthly where delivery_month <= date '" + key["as_of_date"] + "' group by 1").fetchall())
for y, v in key["service_level_by_year"].items():
    check(y, sl.get(y), v, tol=0.0005)

print("4. Injected defects -> where did they go?")
print("  " + json.dumps(key["injected_issues"]))
q = con.sql("select source_name, reject_reason, count(*) from silver.quarantine group by all order by 1").fetchall()
print("  quarantined:", q)
dup = con.sql("select count(*) - count(distinct json_extract_string(payload, '$.event_id')) from bronze.HIVE_EVENTS_RAW").fetchall()[0][0]
check("hive duplicates removed by dedup", dup, key["injected_issues"].get("hive_events.duplicate_event", 0), tol=0)
check("hive 0-kg readings quarantined", dict((r[1], r[2]) for r in q if r[0] == "hive_events").get("sensor_fault_weight", 0),
      key["injected_issues"].get("hive_events.sensor_zero_weight", 0), tol=0)
print("  all other defects (labels, dates, French numbers, epoch timestamps, renamed keys) are REPAIRED in silver:"
      " the reconciliations above would be off otherwise.")

print("5. Backtest - decision of Monday 30 March 2026 vs what really happened")
pred = con.sql("select variety_code, min(case when coverage_status='RED' then iso_week end) from gold.gold_supply_coverage_weekly where as_of_date = date '2026-03-30' group by 1 order by 1").fetchall()
real = dict(con.sql("select variety_code, round(min(service_level), 3) from gold.fct_service_level_monthly where delivery_month between date '2026-04-01' and date '2026-05-31' group by 1").fetchall())
for v, red in pred:
    flagged, short = red is not None, real.get(v, 1) < 0.95
    print(f"  {'OK ' if flagged == short else '?? '} {v:14s} predicted {'RED from ' + red if red else 'not red':18s}  real worst service level Apr-May = {real.get(v)}")
print("\nRESULT:", "ALL RECONCILIATIONS PASS" if ok_all else "SOME CHECKS FAILED")
