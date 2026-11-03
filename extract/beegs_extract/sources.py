"""The 5 REAL external sources pulled by the extract job (+ the reference file loaded by hand).

| Source                     | What we use it for                                         | Method                         |
|----------------------------|------------------------------------------------------------|--------------------------------|
| Open-Meteo archive (ERA5)  | daily weather at each apiary -> "foraging days" signal     | API pull, incremental watermark|
| Open-Meteo forecast        | next 7 days weather at each apiary -> flow at risk         | API pull, daily overwrite      |
| Frankfurter (ECB rates)    | EUR/HUF, EUR/RON, EUR/USD -> price partner & spot offers   | API pull, incremental watermark|
| GBIF occurrences           | flowering observations of 8 honey plants in FR/HU/RO       | API pull, weekly yearly facets |
| Eurostat Comext DS-045409  | EU honey (HS 0409) import value/quantity -> spot price     | manual monthly CSV drop (batch)|
| FranceAgriMer 2024 report  | bulk price per variety, yields                             | dbt seed (versioned reference) |

Every call: timeout, retries with back-off, raise_for_status (fail loudly), raw payload landed untouched
(bronze = what the source said, so we can always replay the transformations).
"""
from __future__ import annotations

import csv
import datetime as dt
import json
import logging
import time
from pathlib import Path

import requests

log = logging.getLogger("beegs.extract.sources")
UA = {"User-Agent": "BeeGs-data-platform/1.0 (student project; contact: data@beegs.example)"}

ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"                 # ERA5 reanalysis (preferred)
HIST_FORECAST_URL = "https://historical-forecast-api.open-meteo.com/v1/forecast"  # fallback (INC-004)
HIST_FORECAST_FIRST_DAY = dt.date(2022, 1, 1)
OPEN_METEO_DAILY = "temperature_2m_max,temperature_2m_min,precipitation_sum,wind_speed_10m_max,sunshine_duration"
FX_SYMBOLS = "HUF,RON,USD,PLN"
# Melliferous plants behind our 8 varieties (scientific names, GBIF backbone)
GBIF_PLANTS = {
    "ACACIA": "Robinia pseudoacacia",
    "LAVANDE": "Lavandula angustifolia",
    "CHATAIGNIER": "Castanea sativa",
    "TILLEUL": "Tilia cordata",
    "TOURNESOL": "Helianthus annuus",
    "COLZA": "Brassica napus",
    "MONTAGNE": "Rhododendron ferrugineum",
    "TOUTES_FLEURS": "Taraxacum officinale",
}


def http_get_json(url: str, params: dict, retries: int = 4, timeout: int = 30):
    for attempt in range(1, retries + 1):
        try:
            r = requests.get(url, params=params, headers=UA, timeout=timeout)
            if r.status_code == 429 or r.status_code >= 500:   # transient: rate limit / server error
                raise requests.HTTPError(f"transient {r.status_code}", response=r)
            r.raise_for_status()                                 # 4xx other than 429 = our bug: fail now
            return r.json()
        except (requests.ConnectionError, requests.Timeout, requests.HTTPError) as e:
            transient = not isinstance(e, requests.HTTPError) or "transient" in str(e)
            if attempt == retries or not transient:
                raise
            wait = 2 ** attempt
            log.warning(f"GET {url} failed ({e}); retry {attempt}/{retries} in {wait}s")
            time.sleep(wait)


def load_apiaries(path: Path) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def _envelope(source: str, request: dict, payload, run_date: dt.date) -> bytes:
    """Bronze envelope: raw payload + lineage metadata (source, request, extraction time, run date)."""
    return json.dumps({
        "source": source, "run_date": run_date.isoformat(),
        "extracted_at": dt.datetime.now(dt.timezone.utc).isoformat(), "request": request, "payload": payload,
    }).encode()


def extract_open_meteo_archive(sink, apiaries, run_date: dt.date, backfill_from: dt.date | None = None):
    """Incremental: from (watermark + 1 day) to run_date. ERA5 lags ~5 days, so we always re-read the last 7 days
    (overlap) - the silver layer keeps the latest extraction per (apiary, date): overlap = no gap, no duplicate."""
    state = sink.get_state("open_meteo_archive")
    if backfill_from:
        start = backfill_from - dt.timedelta(days=365 * 3)       # 3 extra years -> seasonal norms
    elif state.get("watermark"):
        start = dt.date.fromisoformat(state["watermark"]) - dt.timedelta(days=7)
    else:
        # no watermark = the history was never landed (e.g. the API was down during the backfill): catch up fully
        start = dt.date(2021, 1, 1)
    # long ranges (backfill) are cut into yearly chunks: one ~6-year ERA5 query per apiary times out on the API side
    chunks, c = [], start
    while c <= run_date:
        c_end = min(dt.date(c.year, 12, 31), run_date)
        chunks.append((c, c_end))
        c = c_end + dt.timedelta(days=1)
    n = 0
    # Circuit breaker: the ERA5 archive endpoint had a multi-hour outage (INC-004, 2 Nov 2026). After its first
    # failure we switch to Open-Meteo's historical-forecast endpoint: same JSON, same variables, data from 2022 on.
    # The endpoint actually used is kept in the envelope (lineage), so silver knows which source each day came from.
    endpoint = ARCHIVE_URL
    for ap in apiaries:
        for c_start, c_end in chunks:
            params = {"latitude": ap["latitude"], "longitude": ap["longitude"], "start_date": c_start.isoformat(),
                      "end_date": c_end.isoformat(), "daily": OPEN_METEO_DAILY, "timezone": "Europe/Paris"}
            payload = None
            if endpoint == ARCHIVE_URL:
                try:
                    payload = http_get_json(ARCHIVE_URL, params, retries=2, timeout=60)
                except requests.RequestException as e:
                    log.warning(json.dumps({"source": "open_meteo_archive", "fallback": HIST_FORECAST_URL, "reason": str(e)[:200]}))
                    endpoint = HIST_FORECAST_URL
            if payload is None:
                if c_end < HIST_FORECAST_FIRST_DAY:
                    continue                                   # the fallback has no data before 2022
                params["start_date"] = max(c_start, HIST_FORECAST_FIRST_DAY).isoformat()
                payload = http_get_json(HIST_FORECAST_URL, params, timeout=90)
            params["apiary_id"] = ap["apiary_id"]
            params["endpoint"] = endpoint
            sink.put_bytes(_envelope("open_meteo_archive", params, payload, run_date),
                           f"landing/weather_daily/dt={run_date.isoformat()}/{ap['apiary_id']}_{c_start:%Y%m%d}_{c_end:%Y%m%d}.json")
            n += len(payload.get("daily", {}).get("time", []))
    sink.set_state("open_meteo_archive", {"watermark": run_date.isoformat()})
    return {"rows": n, "from": start.isoformat()}


def extract_open_meteo_forecast(sink, apiaries, run_date: dt.date):
    n = 0
    for ap in apiaries:
        params = {"latitude": ap["latitude"], "longitude": ap["longitude"], "daily": OPEN_METEO_DAILY,
                  "forecast_days": 8, "timezone": "Europe/Paris"}
        payload = http_get_json("https://api.open-meteo.com/v1/forecast", params)
        params["apiary_id"] = ap["apiary_id"]
        sink.put_bytes(_envelope("open_meteo_forecast", params, payload, run_date),
                       f"landing/weather_forecast/dt={run_date.isoformat()}/{ap['apiary_id']}.json")
        n += len(payload.get("daily", {}).get("time", []))
    return {"rows": n}


def extract_frankfurter(sink, run_date: dt.date, backfill_from: dt.date | None = None):
    state = sink.get_state("frankfurter")
    start = backfill_from or (dt.date.fromisoformat(state["watermark"]) + dt.timedelta(days=1) if state.get("watermark")
                              else run_date - dt.timedelta(days=30))
    if start > run_date:
        return {"rows": 0, "skipped": "up to date"}
    params = {"base": "EUR", "symbols": FX_SYMBOLS}
    payload = http_get_json(f"https://api.frankfurter.dev/v1/{start.isoformat()}..{run_date.isoformat()}", params)
    sink.put_bytes(_envelope("frankfurter", {**params, "start": start.isoformat(), "end": run_date.isoformat()}, payload, run_date),
                   f"landing/fx_rates/dt={run_date.isoformat()}/eur_{start:%Y%m%d}_{run_date:%Y%m%d}.json")
    sink.set_state("frankfurter", {"watermark": run_date.isoformat()})
    return {"rows": len(payload.get("rates", {})), "from": start.isoformat()}


def extract_gbif(sink, run_date: dt.date, years=None):
    """Monthly counts of observations per plant & country (facet on month). Re-pulled weekly (Mondays) for the
    current year because citizen-science records arrive late; history pulled once at backfill."""
    if years is None:
        if run_date.weekday() != 0:
            return {"skipped": "GBIF refreshed on Mondays only"}
        years = [run_date.year]
    n = 0
    for year in years:
        for variety, plant in GBIF_PLANTS.items():
            for country in ("FR", "HU", "RO"):
                params = {"scientificName": plant, "country": country, "year": year, "limit": 0,
                          "facet": "month", "facetLimit": 12, "hasCoordinate": "true"}
                payload = http_get_json("https://api.gbif.org/v1/occurrence/search", params)
                params["variety"] = variety
                sink.put_bytes(_envelope("gbif", params, payload, run_date),
                               f"landing/gbif_bloom/dt={run_date.isoformat()}/{variety}_{country}_{year}.json")
                n += 1
                time.sleep(0.2)   # be polite with a free public API
    return {"calls": n}


EUROSTAT_URL = ("https://ec.europa.eu/eurostat/api/comext/dissemination/sdmx/2.1/data/DS-045409/"
                "M.EU27_2020.UA+CN+AR+MX+TR+MD+VN+BR+NZ.0409.1.VALUE_IN_EUROS+QUANTITY_IN_100KG")


def extract_eurostat(sink, run_date: dt.date, force: bool = False):
    """REAL Eurostat Comext (SDMX 2.1 API, SDMX-CSV): EU27 imports of natural honey (HS 0409) from the main
    extra-EU origins, monthly. Published with ~45 days of lag -> pulled on the 1st and 15th of the month (or at
    backfill), last 36 months, the whole file replaced (the latest months get revised by Eurostat).
    Tolerant: an Eurostat outage must not block the daily pipeline (the spot price just keeps its last value)."""
    if not force and run_date.day not in (1, 15) and sink.get_state("eurostat").get("watermark"):
        return {"skipped": "Eurostat refreshed on the 1st and 15th"}
    start = (run_date.replace(day=1) - dt.timedelta(days=3 * 365)).strftime("%Y-%m")
    try:
        r = requests.get(EUROSTAT_URL, params={"format": "SDMX-CSV", "startPeriod": start}, headers=UA, timeout=120)
        r.raise_for_status()
        text = r.text
        if not text.startswith("DATAFLOW"):
            raise ValueError(f"unexpected Eurostat payload: {text[:120]!r}")
    except Exception as e:  # noqa: BLE001 - logged and reported, never silent
        log.warning(f"Eurostat pull failed, keeping the previous file: {e}")
        return {"error": str(e)[:200]}
    sink.put_bytes(text.encode(), f"landing/eurostat_honey_imports/dt={run_date.isoformat()}/ds-045409_0409_{run_date:%Y%m%d}.csv")
    sink.set_state("eurostat", {"watermark": run_date.isoformat()})
    return {"rows": text.count("\n") - 1, "from": start}
