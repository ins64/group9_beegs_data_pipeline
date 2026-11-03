"""
LOCAL DEVELOPMENT: load data/landing/** into a DuckDB file with EXACTLY the bronze tables of Snowflake
(same names, same columns, same _source_file/_file_row_number/_loaded_at lineage columns).

Lets every team member run `dbt build --target local` on a laptop for free, before touching Snowflake.
Usage:  python scripts/local_load_duckdb.py [--landing data/landing] [--db data/beegs_local.duckdb]
"""
import argparse
import csv
import datetime as dt
import json
from pathlib import Path

import duckdb
import pandas as pd

JSON_TABLES = {
    "erp_order_lines": "ERP_ORDER_LINES_RAW", "hive_events": "HIVE_EVENTS_RAW", "weather_daily": "WEATHER_DAILY_RAW",
    "weather_forecast": "WEATHER_FORECAST_RAW", "fx_rates": "FX_RATES_RAW", "gbif_bloom": "GBIF_BLOOM_RAW",
}
CSV_TABLES = {
    "lab_results": ("LAB_RESULTS_RAW", "sample_id lot_id lab_name analysis_date declared_variety moisture_pct hmf_mg_kg pollen_origin_match c4_sugar_pct verdict"),
    "wms_stock": ("WMS_STOCK_RAW", "snapshot_date lot_id variety location kg_remaining status received_date supplier_id"),
    "harvest_declarations": ("HARVEST_DECLARATIONS_RAW", "declaration_id beekeeper_id variety declared_kg expected_week price_per_kg currency declared_at status delivered_kg updated_at"),
    "beekeepers": ("BEEKEEPERS_RAW", "beekeeper_id full_name email phone iban apiary_id country_code currency hives_count is_organic partner_since"),
    "erp_customers": ("ERP_CUSTOMERS_RAW", "customer_id company_name segment country_code contact_email created_at main_varieties"),
}
EUROSTAT_COLS = "dataflow last_update freq reporter partner product flow indicators time_period obs_value obs_flag".split()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--landing", default="data/landing")
    p.add_argument("--db", default="data/beegs_local.duckdb")
    a = p.parse_args()
    land = Path(a.landing)
    con = duckdb.connect(a.db)
    con.execute("CREATE SCHEMA IF NOT EXISTS bronze")
    meta = "_source_file VARCHAR, _file_row_number BIGINT, _loaded_at TIMESTAMPTZ"
    for folder, table in JSON_TABLES.items():
        con.execute(f"CREATE OR REPLACE TABLE bronze.{table} (payload JSON, {meta})")
        rows = []
        for f in sorted((land / folder).rglob("*.json*")):
            # file loaded "at" the end of its partition day -> realistic _loaded_at for freshness tests
            day = f.parent.name.replace("dt=", "")
            loaded = dt.datetime.fromisoformat(day + "T06:30:00+01:00") + dt.timedelta(days=1)
            text = f.read_text(encoding="utf-8")
            lines = text.splitlines() if f.suffix == ".jsonl" else [text]
            for i, line in enumerate(lines, 1):
                if line.strip():
                    rows.append((line, f"landing/{f.relative_to(land).as_posix()}", i, loaded))
        df = pd.DataFrame(rows, columns=["payload", "_source_file", "_file_row_number", "_loaded_at"])
        con.execute(f"INSERT INTO bronze.{table} SELECT * FROM df")
        print(f"{table:28s} {len(rows):>9,} rows")
    for folder, (table, cols) in CSV_TABLES.items():
        cols = cols.split()
        con.execute(f"CREATE OR REPLACE TABLE bronze.{table} ({', '.join(c + ' VARCHAR' for c in cols)}, {meta})")
        rows = []
        for f in sorted((land / folder).rglob("*.csv")):
            day = f.parent.name.replace("dt=", "")
            loaded = dt.datetime.fromisoformat(day + "T06:30:00+01:00") + dt.timedelta(days=1)
            with open(f, newline="", encoding="utf-8") as fh:
                for i, r in enumerate(csv.DictReader(fh), 1):   # by column NAME, like MATCH_BY_COLUMN_NAME
                    rows.append(tuple((r.get(c) or None) for c in cols) + (f"landing/{f.relative_to(land).as_posix()}", i, loaded))
        df = pd.DataFrame(rows, columns=cols + ["_source_file", "_file_row_number", "_loaded_at"])
        con.execute(f"INSERT INTO bronze.{table} SELECT * FROM df")
        print(f"{table:28s} {len(rows):>9,} rows")
    con.execute(f"CREATE OR REPLACE TABLE bronze.EUROSTAT_HONEY_IMPORTS_RAW ({', '.join(c + ' VARCHAR' for c in EUROSTAT_COLS)}, {meta})")
    rows = []
    for f in sorted((land / "eurostat_honey_imports").rglob("*.csv")):
        with open(f, newline="", encoding="utf-8") as fh:
            rd = csv.reader(fh)
            next(rd)
            for i, r in enumerate(rd, 1):
                rows.append(tuple(r[:11]) + (f"landing/{f.relative_to(land).as_posix()}", i, dt.datetime.now(dt.timezone.utc)))
    df = pd.DataFrame(rows, columns=EUROSTAT_COLS + ["_source_file", "_file_row_number", "_loaded_at"])
    con.execute("INSERT INTO bronze.EUROSTAT_HONEY_IMPORTS_RAW SELECT * FROM df")
    print(f"{'EUROSTAT_HONEY_IMPORTS_RAW':28s} {len(rows):>9,} rows")
    con.close()


if __name__ == "__main__":
    main()
