"""
Builds architecture/beegs_architecture.excalidraw (open it on excalidraw.com: File > Open).
Diagram as code: the diagram is regenerated from this file, so it never drifts from the documentation (docs/03).
Every arrow carries its ingestion method; numbers (1)...(12) match the table in docs/03_architecture_and_tools.md.
"""
import base64
import json
import random
from pathlib import Path

ICONS = Path(__file__).with_name("icons")   # brand logos: Simple Icons (CC0), recoloured with the brand colour
FILES = {}
BRAND = {"snowflake": "#29B5E8", "githubactions": "#2088FF", "docker": "#2496ED", "dbt": "#FF694B",
         "streamlit": "#FF4B4B", "opentofu": "#C9A200", "googlecloud": "#4285F4", "python": "#3776AB",
         "duckdb": "#1A1A1A", "github": "#181717"}
# generic symbols drawn here (24x24, stroke icons)
SYMBOLS = {
    "clock": '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 3"/>',
    "mail": '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>',
    "lock": '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    "user": '<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 4-6 8-6s8 2 8 6"/>',
    "folder": '<path d="M3 6h6l2 2h10v11H3z"/>',
    "cloud": '<path d="M7 18h10a4 4 0 0 0 0-8 6 6 0 0 0-11.5 1.5A3.5 3.5 0 0 0 7 18z"/>',
    "db": '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    "api": '<path d="M8 6l-6 6 6 6M16 6l6 6-6 6"/>',
    "factory": '<path d="M3 21V10l6 4V10l6 4V6l6 3v12z"/>',
    "scale": '<path d="M12 3v18M5 7h14M5 7l-3 7a3 3 0 0 0 6 0zM19 7l-3 7a3 3 0 0 0 6 0z"/>',
    "flask": '<path d="M9 3h6M10 3v6l-6 10a2 2 0 0 0 2 3h12a2 2 0 0 0 2-3l-6-10V3"/>',
    "chart": '<path d="M3 21h18M6 17v-5M11 17V7M16 17v-8"/>',
    "euro": '<path d="M18 6a7 7 0 1 0 0 12M4 10h10M4 14h10"/>',
    "alert": '<path d="M12 3l10 18H2z"/><path d="M12 10v5M12 18v.5"/>',
    "flower": '<circle cx="12" cy="9" r="2.5"/><path d="M12 6.5a3 3 0 1 1 0-0.1M9.6 8.2a3 3 0 1 1 0 .1M14.4 8.2a3 3 0 1 1 0 .1M10.5 11.2a3 3 0 1 1 0 .1M13.5 11.2a3 3 0 1 1 0 .1M12 12v10M12 18c-2-2-4-2-5-1M12 16c2-2 4-2 5-1"/>',
    "file": '<path d="M6 2h9l5 5v15H6z"/><path d="M14 2v6h6"/>',
}


def _data_url(name, color):
    if name in SYMBOLS:
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="{color}" '
               f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{SYMBOLS[name]}</svg>')
    else:
        svg = (ICONS / f"{name}.svg").read_text().replace("<svg ", f'<svg fill="{BRAND.get(name, color)}" ', 1)
    return "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode()


def icon(x, y, name, size=34, color="#2b0f06"):
    """A logo or symbol as an Excalidraw image element (the SVG is embedded in the file)."""
    fid = f"icon-{name}-{color.strip('#')}"
    FILES.setdefault(fid, {"mimeType": "image/svg+xml", "id": fid, "dataURL": _data_url(name, color),
                           "created": 1, "lastRetrieved": 1})
    e = _base("image", x, y, size, size, stroke="transparent")
    e.update({"fileId": fid, "status": "saved", "scale": [1, 1], "roundness": None})
    EL.append(e)
    return e

R = random.Random(42)
EL = []

BROWN, ORANGE, HONEY, CREAM, GREEN, BLUE, GREY, RED = "#2b0f06", "#e8820c", "#fcd34d", "#fff7e6", "#4e8f3a", "#1971c2", "#868e96", "#c0392b"


def _base(t, x, y, w, h, **kw):
    e = {"id": f"{t}-{len(EL)}", "type": t, "x": x, "y": y, "width": w, "height": h, "angle": 0,
         "strokeColor": kw.get("stroke", BROWN), "backgroundColor": kw.get("bg", "transparent"),
         "fillStyle": kw.get("fill", "solid"), "strokeWidth": kw.get("sw", 2), "strokeStyle": kw.get("style", "solid"),
         "roughness": kw.get("rough", 1), "opacity": 100, "groupIds": [], "frameId": None,
         "roundness": {"type": 3} if t == "rectangle" else ({"type": 2} if t == "arrow" else None),
         "seed": R.randint(1, 2**31), "version": 1, "versionNonce": R.randint(1, 2**31), "isDeleted": False,
         "boundElements": [], "updated": 1, "link": None, "locked": False}
    return e


def text(x, y, s, size=16, color=BROWN, align="left", w=None, family=1):
    lines = s.split("\n")
    if len(lines) > 1:   # one element per line: renders identically in every Excalidraw version
        for i, line in enumerate(lines):
            last = text(x, y + i * size * 1.25, line, size, color, align, w, family)
        return last
    width = w or max(len(l) for l in lines) * size * 0.55
    e = _base("text", x, y, width, len(lines) * size * 1.25, stroke=color)
    e.update({"text": s, "originalText": s, "fontSize": size, "fontFamily": family, "textAlign": align,
              "verticalAlign": "top", "containerId": None, "lineHeight": 1.25, "baseline": size})
    EL.append(e)
    return e


def box(x, y, w, h, title, body="", bg=CREAM, stroke=BROWN, title_color=None, size=15, style="solid", dashed=False):
    r = _base("rectangle", x, y, w, h, bg=bg, stroke=stroke, style="dashed" if dashed else style)
    EL.append(r)
    text(x + 10, y + 8, title, size=size + 1, color=title_color or stroke, w=w - 20)
    if body:
        text(x + 10, y + 12 + (size + 1) * 1.3 * (title.count("\n") + 1), body, size=size - 3, color=BROWN, w=w - 20)
    return r


def tag(x, y, w, *names, size=30, color="#2b0f06"):
    """Logos/symbols in the top-right corner of a box (x, y, w = the box)."""
    for i, n in enumerate(reversed(names)):
        icon(x + w - 10 - size - i * (size + 6), y + 8, n, size=size, color=color)


def zone(x, y, w, h, label, color):
    r = _base("rectangle", x, y, w, h, bg="transparent", stroke=color, style="dashed", sw=2, rough=0)
    EL.append(r)
    text(x + 12, y + 8, label, size=22, color=color, family=1)


def arrow(x1, y1, x2, y2, label="", color=BROWN, dashed=False, lx=None, ly=None, size=12, mid=None):
    pts = [[0, 0], [x2 - x1, y2 - y1]] if mid is None else [[0, 0], [mid[0] - x1, mid[1] - y1], [x2 - x1, y2 - y1]]
    a = _base("arrow", x1, y1, abs(x2 - x1), abs(y2 - y1), stroke=color, style="dashed" if dashed else "solid", sw=2)
    a.update({"points": pts, "lastCommittedPoint": None, "startBinding": None, "endBinding": None,
              "startArrowhead": None, "endArrowhead": "arrow"})
    EL.append(a)
    if label:
        text(lx if lx is not None else (x1 + x2) / 2 - len(label.split("\n")[0]) * size * 0.27,
             ly if ly is not None else (y1 + y2) / 2 - size * 1.6, label, size=size, color=color)


# ------------------------------------------------------------------ title
text(40, 20, "BeeG's · supply coverage pipeline  (Snowflake-centric)", size=36, color=BROWN)
text(40, 68, "\"Will we have enough lab-approved honey to serve our B2B contracts in each of the next 8 weeks?\"  ·  decision: Head of Sourcing, every Monday",
     size=17, color=ORANGE)

# ------------------------------------------------------------------ zones
zone(30, 110, 360, 1010, "1 · SOURCES", BROWN)
zone(420, 110, 470, 1010, "2 · COMPUTE (GitHub Actions)", BLUE)
zone(920, 110, 1250, 1010, "3 · SNOWFLAKE  (on Google Cloud europe-west2)", ORANGE)
zone(2200, 110, 320, 1010, "4 · CONSUMPTION", GREEN)
icon(780, 114, "githubactions", size=28)
icon(1600, 114, "snowflake", size=28)
icon(1636, 114, "googlecloud", size=28)
icon(2470, 114, "streamlit", size=28)

# ------------------------------------------------------------------ sources
text(50, 150, "REAL, external (free APIs)", size=15, color=GREEN)
box(50, 180, 320, 62, "Open-Meteo archive + forecast", "weather, 12 apiaries (JSON) · down: INC-004", bg="#e9f5e1", stroke=GREEN)
tag(50, 180, 320, "cloud", color=GREEN)
box(50, 252, 320, 62, "Frankfurter = ECB rates", "EUR->HUF, RON, USD, PLN (JSON)", bg="#e9f5e1", stroke=GREEN)
tag(50, 252, 320, "euro", color=GREEN)
box(50, 324, 320, 62, "GBIF occurrences", "flowering of 8 honey plants (JSON)", bg="#e9f5e1", stroke=GREEN)
tag(50, 324, 320, "flower", color=GREEN)
box(50, 396, 320, 62, "Eurostat Comext DS-045409", "EU honey imports EUR/kg, monthly (SDMX API)", bg="#e9f5e1", stroke=GREEN)
tag(50, 396, 320, "chart", color=GREEN)
box(50, 468, 320, 62, "FranceAgriMer 2024", "bulk price per variety (8 values, report fig. 15)", bg="#e9f5e1", stroke=GREEN)
tag(50, 468, 320, "file", color=GREEN)
text(50, 555, "INTERNAL systems (simulated, messy, seed 42)", size=15, color=BROWN)
box(50, 585, 320, 62, "ERP · order lines + customers", "B2B call-offs, webshop · JSONL / CSV", bg=CREAM)
tag(50, 585, 320, "factory")
box(50, 657, 320, 62, "WMS · stock snapshot", "every lot, every day · 348 k rows", bg=CREAM)
tag(50, 657, 320, "db")
box(50, 729, 320, 62, "Beekeeper portal", "harvest declarations · PII (email, IBAN)", bg=CREAM)
tag(50, 729, 320, "user")
box(50, 801, 320, 62, "LIMS · 2 labs", "moisture, HMF, pollen, verdict · CSV", bg=CREAM)
tag(50, 801, 320, "flask")
box(50, 873, 320, 62, "IoT hive scales (24 hives)", "weight every 4 h · 151 k events", bg=HONEY)
tag(50, 873, 320, "scale")
text(50, 960, "12 sources · 16 kinds of defects injected\nand counted (answer key)", size=14, color=GREY)

# ------------------------------------------------------------------ compute (GitHub Actions)
box(440, 170, 430, 80, "Schedules (GitHub cron, UTC)", "extract-daily 03:17 UTC = 04:17 Paris (+ fallback) · hive-readings every 4 h", bg="#e7f0fb", stroke=BLUE)
tag(440, 170, 430, "clock", "githubactions", color=BLUE)
box(440, 280, 430, 150, "Extract container (Docker, GHCR)", "task apis: (1) API pull, incremental watermark\neach source isolated · 2 attempts · 20 min cap\nkey-pair of BEEGS_PIPELINE_SVC (GitHub secret)", bg="#e7f0fb", stroke=BLUE)
tag(440, 280, 430, "docker", "python")
box(440, 600, 430, 110, "task internal  (runs first)", "(7) daily exports: changed rows / snapshots\n+ trigger Snowpipe for lab files (10)", bg="#e7f0fb", stroke=BLUE)
tag(440, 600, 430, "docker")
box(440, 850, 430, 100, "task hive  (every 4 h)", "(11) last 4 h of readings -> 1 JSONL file\n+ trigger Snowpipe", bg="#e7f0fb", stroke=BLUE)
tag(440, 850, 430, "docker")
box(440, 460, 430, 90, "task apis · Eurostat (1st + 15th)", "(5) SDMX API, last 36 months replaced\n(absorbs Eurostat's revisions)", bg="#e7f0fb", stroke=BLUE)
tag(440, 460, 430, "docker")
arrow(655, 250, 655, 280, "", color=BLUE)
arrow(370, 280, 440, 330, "", color=GREEN)
arrow(370, 427, 440, 500, "", color=GREEN)
arrow(370, 690, 440, 655, "", color=BROWN)
arrow(370, 832, 440, 690, "", color=BROWN)
arrow(370, 904, 440, 900, "", color=BROWN)

# ------------------------------------------------------------------ snowflake
box(940, 270, 270, 560, "LANDING ZONE\n@OPS.LANDING", "internal stage\n(server-side encrypted)\n\n<source>/dt=YYYY-MM-DD/\n\n• raw files, untouched\n• replayable\n• directory table =\n  inventory of files\n• PUT ... OVERWRITE\n  (rerun = same file)", bg="#fdebd3", stroke=ORANGE)
tag(940, 270, 270, "folder", color=ORANGE)
arrow(870, 355, 940, 355, "(2) PUT", color=BLUE, lx=880, ly=325)
arrow(870, 505, 940, 505, "(5) PUT", color=BLUE, lx=880, ly=475)
arrow(870, 655, 940, 655, "(8) PUT", color=BLUE, lx=880, ly=625)
arrow(870, 900, 940, 780, "(12) PUT", color=BLUE, lx=880, ly=870)
box(940, 150, 1210, 95, "Task graph 06:30 Paris:  ROOT -> LOAD_BATCH -> CHECK_COMPLETE -> DBT_BUILD",
    "+ FINALIZER (always: run log + e-mail on failure) · retries x2 · suspended after 3 failures\nidempotent steps · dbt build runs as a dbt Project on Snowflake", bg="#fdebd3", stroke=ORANGE)
tag(940, 150, 1210, "clock", "snowflake", "dbt", color=ORANGE)
box(1250, 270, 260, 560, "BRONZE", "12 raw tables\nVARIANT (JSON)\nVARCHAR (CSV)\n\n+ _source_file\n+ _file_row_number\n+ _loaded_at\n\n7 days Time Travel\n\nPII masked\n(MASK_PII_RAW)", bg="#f4e2c6", stroke=BROWN)
tag(1250, 270, 260, "db")
box(1550, 270, 280, 560, "SILVER  (dbt)", "12 stg_* :\n typing, cleaning,\n dedup, reject_reason\n\nQUARANTINE\n (every rejected row\n  + its reason)\n\n12 int_* :\n as-of logic, reliability,\n pass rate, flow index,\n intake, demand, prices\n\nincremental MERGE", bg="#fbd38d", stroke=BROWN)
tag(1550, 270, 280, "dbt")
box(1870, 270, 280, 560, "GOLD  (dbt)", "gold_supply_coverage\n _weekly  (decision)\ngold_coverage_actions\nfct_service_level_monthly\nfct_order_lines\ndim_variety / customer\ndim_beekeeper (masked)\ngold_apiary_signals\ngold_pipeline_health\nDECISION_LOG", bg=ORANGE, stroke=BROWN)
tag(1870, 270, 280, "dbt")
arrow(1210, 420, 1250, 420, "", color=ORANGE)
text(1180, 380, "(3)(6)(9)\nCOPY INTO", size=12, color=ORANGE)
arrow(1210, 700, 1250, 700, "", color=ORANGE)
text(1180, 715, "(10)(12)\nSnowpipe", size=12, color=ORANGE)
arrow(1510, 550, 1550, 550, "", color=BROWN)
arrow(1830, 550, 1870, 550, "", color=BROWN)
text(1250, 840, "dbt build: 34 models · 79 tests (keys, relationships, business rules, unit test) · a failed test upstream SKIPS gold", size=13, color=BROWN)
text(1560, 245 + 0, "", size=1)
arrow(370, 499, 1600, 290, "", color=GREEN, dashed=True, mid=[900, 120])
text(1660, 248, "seed: FranceAgriMer", size=12, color=GREEN)
box(940, 880, 600, 220, "Governance & operations",
    "• roles: ADMIN / PIPELINE / PURCHASING / ANALYST · service users key-pair only\n• masking policies on PII · tags (sensitivity, owner, domain) · ACCESS_HISTORY audit\n• resource monitor 15 credits (notify 75 %, suspend 100 %) + Budget (incl. serverless)\n• Data Metric Functions on micro-batch tables\n• serverless alerts: hive feed stale (2 h), coverage RED (07:30)\n• PIPELINE_RUN_LOG · FinOps views (cost per run, per decision)", bg="#f8f9fa", stroke=GREY)
tag(940, 880, 600, "lock", color=GREY)
box(1570, 880, 580, 220, "Warehouses (XS, auto-suspend 60 s)",
    "BEEGS_PIPELINE_WH: load + dbt\nBEEGS_BI_WH: dashboard + analysts\n\n~ 4 credits/month ~ EUR 15 = EUR 3.50 per weekly decision\nGitHub Actions within the free quota (EUR 0)", bg="#f8f9fa", stroke=GREY)
tag(1570, 880, 580, "euro", "snowflake", color=GREY)

# ------------------------------------------------------------------ consumption
box(2220, 270, 280, 200, "Streamlit cockpit\n(in Snowflake)", "Head of Sourcing, Monday 08:00\n• heatmap variety x week\n• action + cost of options\n• freshness + costs tiles\n• SAVE DECISION -> SQL INSERT", bg="#e9f5e1", stroke=GREEN)
tag(2220, 270, 280, "streamlit")
box(2220, 510, 280, 120, "E-mail alert", "\"ACACIA RED from W48,\n3.5 t short -> buy partner\nstock EUR 27.4 k / spot EUR 13.0 k\"", bg="#fde2e1", stroke=RED)
tag(2220, 510, 280, "mail", color=RED)
box(2220, 670, 280, 110, "Analysts (read-only)", "GOLD only · PII masked\nBRONZE/SILVER denied", bg="#f1f3f5", stroke=GREY)
tag(2220, 670, 280, "user", color=GREY)
arrow(2150, 370, 2220, 370, "", color=GREEN)
arrow(2150, 570, 2220, 570, "", color=RED)
arrow(2150, 720, 2220, 720, "", color=GREY)
text(2220, 810, "Business outcome:\nB2B service level >= 95 %\n(2025: 84.6 %, EUR 294 k lost)", size=15, color=GREEN)

# ------------------------------------------------------------------ bottom band: IaC / CI
box(30, 1150, 1260, 100, "IaC · OpenTofu (terraform/snowflake)",
    "2 warehouses · database · 4 schemas · 3 functional roles + hierarchy · ~20 grants\nstate ENCRYPTED (AES-GCM) in @BEEGS_INFRA.TFSTATE.STATE · lock = CI concurrency · only manual step: 00_bootstrap (ACCOUNTADMIN)",
    bg="#e7f0fb", stroke=BLUE, size=15)
tag(30, 1150, 1260, "opentofu", "snowflake")
box(1320, 1150, 1200, 120, "CI/CD · GitHub Actions",
    "ci: generate -> DuckDB -> dbt build (79 tests) -> reconcile · tofu validate · docker build\ndeploy: tofu apply -> SQL 01..08 -> snow dbt deploy -> Streamlit · build-image (GHCR) · backfill\nops: run-pipeline · health-check · incident-drill (INC-002, asserted) · demo-prepare / demo-rehearsal",
    bg="#f1f3f5", stroke=GREY, size=15)
tag(1320, 1150, 1200, "github", "githubactions", "duckdb", "docker")

doc = {"type": "excalidraw", "version": 2, "source": "https://excalidraw.com", "elements": EL,
       "appState": {"viewBackgroundColor": "#ffffff", "gridSize": None}, "files": FILES}
out = Path(__file__).with_name("beegs_architecture.excalidraw")
out.write_text(json.dumps(doc, indent=1))
print(f"{len(EL)} elements -> {out}")
