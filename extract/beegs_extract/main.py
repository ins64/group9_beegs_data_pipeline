"""
BeeG's extract job (container, run by GitHub Actions on a schedule)
==================================================================

One container image, one task per run, chosen with the BEEGS_TASK env var (or --task):

  apis          Pull the REAL external APIs (Open-Meteo archive + forecast, Frankfurter ECB FX, GBIF bloom
                observations) for the run date and land the raw JSON in the Snowflake stage @BEEGS.OPS.LANDING.
                Incremental: each source keeps a watermark in @BEEGS.OPS.EXTRACT_STATE, so a rerun or a backfill
                never re-downloads or double-counts.
  internal      Export the day's increment of the simulated internal systems (ERP, WMS, LIMS, beekeeper
                portal) to the stage, exactly where the real systems would drop their files. Lab files are
                announced to Snowpipe right away (event-driven micro-batch).
  hive          Land the hive-scale readings of the last 4 hours as one JSONL file and announce it to Snowpipe.
  backfill      Upload the full history once (initial load).

The run date comes from --date / BEEGS_RUN_DATE (default: yesterday in Europe/Paris), never from
"now" inside the code, so that backfills and replays are deterministic.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import logging
import os
import sys
import tempfile
from pathlib import Path

from beegs_extract import sources
from beegs_extract.sinks import make_sink

logging.basicConfig(level=logging.INFO, format='{"severity":"%(levelname)s","logger":"%(name)s","message":"%(message)s"}')
log = logging.getLogger("beegs.extract")

# /app in the container, the repository root in local development
ROOT = next(p for p in Path(__file__).resolve().parents if (p / "config" / "apiaries.csv").exists())


def default_run_date() -> dt.date:
    # yesterday in the business time zone (Paris = UTC+1/UTC+2); APIs are queried for complete days only
    return (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=1)).date() - dt.timedelta(days=1)


def simulator(end: dt.date, start: dt.date = dt.date(2024, 1, 1)):
    sys.path.insert(0, str(ROOT / "data_generator"))
    import generate  # noqa: E402  (simulator shipped in the same image)

    sim = generate.Sim(seed=int(os.getenv("BEEGS_SEED", "42")), start=start, end=end,
                       mess=float(os.getenv("BEEGS_MESS", "0.02")), apiaries_csv=ROOT / "config" / "apiaries.csv")
    sim.run()
    return generate, sim


def isolated(name: str, fn, *args, **kwargs):
    """One external API down must not stop the others (nor the internal files): log it, carry on, report it.
    Each source keeps its own watermark, so the next run catches up exactly what was missed."""
    try:
        return fn(*args, **kwargs)
    except Exception as e:  # noqa: BLE001 - reported below and in the run summary
        log.error(json.dumps({"source": name, "status": "failed", "error": str(e)[:300]}))
        return {"status": "failed", "error": str(e)[:300]}


def failed_sources(res: dict) -> list[str]:
    return [k for k, v in res.items() if isinstance(v, dict) and v.get("status") == "failed"]


def task_apis(sink, run_date: dt.date):
    apiaries = sources.load_apiaries(ROOT / "config" / "apiaries.csv")
    res = {
        "weather_daily": isolated("weather_daily", sources.extract_open_meteo_archive, sink, apiaries, run_date),
        "weather_forecast": isolated("weather_forecast", sources.extract_open_meteo_forecast, sink, apiaries, run_date),
        "fx_rates": isolated("fx_rates", sources.extract_frankfurter, sink, run_date),
        "gbif_bloom": isolated("gbif_bloom", sources.extract_gbif, sink, run_date),
        "eurostat": isolated("eurostat", sources.extract_eurostat, sink, run_date),
    }
    if failed_sources(res):
        # every other source has landed; fail the run anyway so that the outage is visible (red run + e-mail)
        raise RuntimeError(f"external sources failed: {failed_sources(res)} - landed: {res}")
    return res


def task_internal(sink, run_date: dt.date):
    """Run the deterministic simulator up to run_date and upload only that day's files."""
    generate, sim = simulator(run_date)
    lab_files = []
    with tempfile.TemporaryDirectory() as tmp:
        generate.write_day(Path(tmp), run_date, sim.daily[run_date])
        n = 0
        for f in Path(tmp).rglob("*"):
            rel = f.relative_to(tmp).as_posix()
            if f.is_file() and not rel.startswith("hive_events/"):   # hive readings have their own 4-hourly job
                sink.put_file(f, f"landing/{rel}")
                n += 1
                if rel.startswith("lab_results/"):
                    lab_files.append(rel)
    sink.notify_pipe("BEEGS.OPS.PIPE_LAB_RESULTS", lab_files)
    return {"files": n, "lab_files_to_snowpipe": len(lab_files)}


def task_hive(sink):
    """Readings of the last 4 hours (the scales report every 4 h) -> one JSONL file -> Snowpipe."""
    now = dt.datetime.now(dt.timezone.utc)
    _, sim = simulator(now.date())
    window_start = now - dt.timedelta(hours=4)
    lines = []
    for ev in sim.daily[now.date()]["hive_events"]:
        ts = ev["ts"]
        t = dt.datetime.fromtimestamp(ts, dt.timezone.utc) if isinstance(ts, int) else dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        if window_start < t <= now:
            lines.append(json.dumps(ev))
    if not lines:
        return {"events": 0}
    rel = f"hive_events/stream/{now:%Y/%m/%d}/hive_{now:%Y%m%dT%H%M}.jsonl"
    sink.put_bytes(("\n".join(lines) + "\n").encode(), f"landing/{rel}")
    sink.notify_pipe("BEEGS.OPS.PIPE_HIVE_EVENTS", [rel])
    return {"events": len(lines), "file": rel}


def task_backfill(sink, start: dt.date, end: dt.date):
    generate, sim = simulator(end, start)
    with tempfile.TemporaryDirectory() as tmp:
        for d in sorted(sim.daily):
            generate.write_day(Path(tmp), d, sim.daily[d])
        sink.put_tree(Path(tmp))
    # real APIs: one historical pull (Open-Meteo archive since start - 3 years, FX since start, GBIF yearly facets)
    apiaries = sources.load_apiaries(ROOT / "config" / "apiaries.csv")
    apis = {
        "weather_daily": isolated("weather_daily", sources.extract_open_meteo_archive, sink, apiaries, end, backfill_from=start),
        "fx_rates": isolated("fx_rates", sources.extract_frankfurter, sink, end, backfill_from=start),
        "gbif_bloom": isolated("gbif_bloom", sources.extract_gbif, sink, end, years=range(start.year - 3, end.year + 1)),
        "eurostat": isolated("eurostat", sources.extract_eurostat, sink, end, force=True),
    }
    # the internal history is landed: the load can go on; a missing API history is caught up by the next daily run
    return {"days": len(sim.daily), "apis": apis, "apis_failed": failed_sources(apis)}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--task", default=os.getenv("BEEGS_TASK", "apis"), choices=["apis", "internal", "hive", "backfill"])
    p.add_argument("--date", default=os.getenv("BEEGS_RUN_DATE") or None)
    p.add_argument("--backfill-from", default=os.getenv("BEEGS_BACKFILL_FROM", "2024-01-01"))
    p.add_argument("--target", default=os.getenv("BEEGS_TARGET", "snowflake"), choices=["snowflake", "local"],
                   help="snowflake = internal stage @BEEGS.OPS.LANDING ; local = ./data (dev without cloud)")
    a = p.parse_args(argv)
    run_date = dt.date.fromisoformat(a.date) if a.date else default_run_date()
    log.info(json.dumps({"task": a.task, "run_date": run_date.isoformat(), "target": a.target}))
    try:
        sink = make_sink(a.target)
        if a.task == "apis":
            res = task_apis(sink, run_date)
        elif a.task == "internal":
            res = task_internal(sink, run_date)
        elif a.task == "hive":
            res = task_hive(sink)
        else:
            res = task_backfill(sink, dt.date.fromisoformat(a.backfill_from), run_date)
    except Exception:
        # Fail loudly: non-zero exit -> the GitHub Actions run is red, retried by the workflow, and e-mailed
        log.exception("extract task failed")
        sys.exit(1)
    log.info(json.dumps({"task": a.task, "status": "success", "result": res}, default=str))


if __name__ == "__main__":
    main()
