"""
LOCAL DEVELOPMENT ONLY - fixtures shaped exactly like the real external API responses.

In the cloud, the extract job lands the REAL Open-Meteo / Frankfurter / GBIF / Eurostat data.
On a laptop without internet access to those APIs (or to work offline), this script writes files with the
same envelope and the same JSON shape, so the dbt project can be built end-to-end on DuckDB.
Every fixture carries "fixture": true in its envelope: they can never be mistaken for real data, and the
dbt staging models flag them (is_fixture) so a dashboard built on them shows it.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import random
from pathlib import Path

PLANTS = ["ACACIA", "LAVANDE", "CHATAIGNIER", "TILLEUL", "TOURNESOL", "COLZA", "MONTAGNE", "TOUTES_FLEURS"]


def env(source, request, payload, run_date):
    return json.dumps({"source": source, "fixture": True, "run_date": run_date.isoformat(),
                       "extracted_at": dt.datetime.now(dt.timezone.utc).isoformat(), "request": request, "payload": payload})


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default="data/landing")
    p.add_argument("--start", default="2021-01-01")
    p.add_argument("--end", default="2026-11-01")
    a = p.parse_args()
    r = random.Random(7)
    out = Path(a.out)
    start, end = dt.date.fromisoformat(a.start), dt.date.fromisoformat(a.end)
    root = next(q for q in Path(__file__).resolve().parents if (q / "config" / "apiaries.csv").exists())
    apiaries = list(csv.DictReader(open(root / "config" / "apiaries.csv", encoding="utf-8")))
    days = [(start + dt.timedelta(days=i)) for i in range((end - start).days + 1)]

    for ap in apiaries:
        lat = float(ap["latitude"])
        tmax, tmin, pr, wind, sun = [], [], [], [], []
        for d in days:
            doy = d.timetuple().tm_yday
            base = 14 + 11 * math.sin((doy - 105) / 365 * 2 * math.pi) - (lat - 44) * 0.6
            tmax.append(round(base + r.gauss(0, 3), 1)); tmin.append(round(base - 9 + r.gauss(0, 2), 1))
            pr.append(round(max(0, r.gauss(-1, 5)), 1)); wind.append(round(abs(r.gauss(15, 8)), 1))
            sun.append(round(max(0, r.gauss(28000 + 12000 * math.sin((doy - 80) / 365 * 2 * math.pi), 9000)), 0))
        payload = {"latitude": lat, "longitude": float(ap["longitude"]), "timezone": "Europe/Paris",
                   "daily_units": {"time": "iso8601", "temperature_2m_max": "°C"},
                   "daily": {"time": [d.isoformat() for d in days], "temperature_2m_max": tmax, "temperature_2m_min": tmin,
                             "precipitation_sum": pr, "wind_speed_10m_max": wind, "sunshine_duration": sun}}
        f = out / "weather_daily" / f"dt={end.isoformat()}" / f"{ap['apiary_id']}_{start:%Y%m%d}_{end:%Y%m%d}.json"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(env("open_meteo_archive", {"apiary_id": ap["apiary_id"]}, payload, end))
        fc_days = [end + dt.timedelta(days=i) for i in range(1, 9)]
        fc = {"daily": {"time": [d.isoformat() for d in fc_days], "temperature_2m_max": [round(r.gauss(12, 3), 1) for _ in fc_days],
                        "temperature_2m_min": [round(r.gauss(4, 2), 1) for _ in fc_days], "precipitation_sum": [round(max(0, r.gauss(1, 4)), 1) for _ in fc_days],
                        "wind_speed_10m_max": [round(abs(r.gauss(15, 8)), 1) for _ in fc_days], "sunshine_duration": [10000.0 for _ in fc_days]}}
        f = out / "weather_forecast" / f"dt={end.isoformat()}" / f"{ap['apiary_id']}.json"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(env("open_meteo_forecast", {"apiary_id": ap["apiary_id"]}, fc, end))

    rates, h, ro, us, pl = {}, 385.0, 4.95, 1.08, 4.30
    for d in days:
        if d.weekday() < 5:  # ECB publishes on working days only - the gaps are real-world behaviour
            h += r.gauss(0, 1.2); ro += r.gauss(0, 0.004); us += r.gauss(0, 0.004); pl += r.gauss(0, 0.01)
            rates[d.isoformat()] = {"HUF": round(h, 2), "RON": round(ro, 4), "USD": round(us, 4), "PLN": round(pl, 4)}
    f = out / "fx_rates" / f"dt={end.isoformat()}" / f"eur_{start:%Y%m%d}_{end:%Y%m%d}.json"
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(env("frankfurter", {"base": "EUR"}, {"amount": 1.0, "base": "EUR", "start_date": start.isoformat(),
                                                      "end_date": end.isoformat(), "rates": rates}, end))

    peak = {"COLZA": 4, "ACACIA": 5, "TOUTES_FLEURS": 5, "TILLEUL": 6, "CHATAIGNIER": 6, "LAVANDE": 7, "MONTAGNE": 7, "TOURNESOL": 8}
    for year in range(start.year, end.year + 1):
        for v in PLANTS:
            for c in ("FR", "HU", "RO"):
                counts = [{"name": str(m), "count": int(max(0, 400 * math.exp(-((m - peak[v]) ** 2) / 2) * r.uniform(0.6, 1.4) * (1 if c == "FR" else 0.2)))}
                          for m in range(1, 13) if not (year == end.year and m > end.month)]
                payload = {"offset": 0, "limit": 0, "endOfRecords": False, "count": sum(x["count"] for x in counts), "results": [],
                           "facets": [{"field": "MONTH", "counts": counts}]}
                f = out / "gbif_bloom" / f"dt={end.isoformat()}" / f"{v}_{c}_{year}.json"
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(env("gbif", {"variety": v, "country": c, "year": year}, payload, end))

    # Eurostat SDMX-CSV export shape (DS-045409), monthly, EU27 imports from extra-EU partners, HS 0409
    f = out / "eurostat_honey_imports" / f"dt={end.isoformat()}" / "ds-045409_0409_fixture.csv"
    f.parent.mkdir(parents=True, exist_ok=True)
    with open(f, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["DATAFLOW", "LAST UPDATE", "freq", "reporter", "partner", "product", "flow", "indicators", "TIME_PERIOD", "OBS_VALUE", "OBS_FLAG"])
        for y in range(2023, end.year + 1):
            for m in range(1, 13):
                if dt.date(y, m, 1) >= end.replace(day=1):
                    break
                for partner, kg100, eur_kg in (("UA", 4200, 2.3), ("CN", 2600, 1.6), ("AR", 1800, 2.5), ("MX", 900, 3.1)):
                    q = round(kg100 * r.uniform(0.7, 1.3))
                    w.writerow(["ESTAT:DS-045409(1.0)", "15/10/26 23:00:00", "M", "EU27_2020", partner, "0409", "1", "QUANTITY_IN_100KG", f"{y}-{m:02d}", q, ""])
                    w.writerow(["ESTAT:DS-045409(1.0)", "15/10/26 23:00:00", "M", "EU27_2020", partner, "0409", "1", "VALUE_IN_EUROS", f"{y}-{m:02d}", round(q * 100 * eur_kg * r.uniform(0.9, 1.1)), ""])
    print("fixtures written (LOCAL DEV ONLY)")


if __name__ == "__main__":
    main()
