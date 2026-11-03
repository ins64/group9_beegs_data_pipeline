"""
BeeG's synthetic source generator
=================================

Simulates the *internal* systems of BeeG's (a fictional French honey trader) day by day
and writes what each system would export, into a local "landing zone" that mirrors the
landing stage layout (@BEEGS.OPS.LANDING/<source>/dt=YYYY-MM-DD/...).

Internal sources simulated (the 5 external sources are REAL APIs/files, see extract/):
  * erp_order_lines        ERP (B2B call-off orders)       JSONL, only rows changed that day (incremental)
  * erp_customers          ERP customer master             CSV full snapshot (weekly)
  * beekeepers             Beekeeper portal master data    CSV full snapshot (weekly)  -> contains PII
  * harvest_declarations   Beekeeper portal declarations   CSV, rows changed that day (incremental)
  * lab_results            LIMS of 2 partner laboratories  CSV per lab per day (event-driven files)
  * wms_stock              Warehouse management system     CSV full snapshot (daily)
  * hive_events            IoT hive scales                 JSON lines (Pub/Sub messages), one file per day for history

The simulation is deterministic for a given --seed: the same seed gives the same files.
Messiness is injected on purpose (like real sources) and every injected issue is counted
in `answer_key.json`, together with the TRUE business figures at the end date. That
answer key is what the gold layer is reconciled against (grading criterion C3).

Usage
-----
    python generate.py --out ../data/landing --start 2024-01-01 --end 2026-11-01
    python generate.py --out ../data/landing --only-date 2026-11-02   # one daily increment
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import random
from collections import defaultdict
from pathlib import Path

# --------------------------------------------------------------------------------------
# Business parameters (all documented in docs/01_business_case.md - explicit assumptions)
# --------------------------------------------------------------------------------------
VARIETIES = {
    # code:        (bulk_price_eur_kg FranceAgriMer 2024, annual B2B demand t, flow weeks, delivery weeks, lab pass rate)
    "TOUTES_FLEURS": (4.6, 70, (15, 28), (24, 36), 0.95),
    "ACACIA":        (7.4, 40, (19, 22), (22, 27), 0.93),
    "CHATAIGNIER":   (7.1, 25, (25, 29), (29, 34), 0.94),
    "LAVANDE":       (8.5, 22, (27, 31), (31, 36), 0.90),
    "TOURNESOL":     (4.0, 20, (28, 33), (33, 39), 0.96),
    "COLZA":         (4.1, 18, (15, 18), (18, 22), 0.96),
    "MONTAGNE":      (7.7, 15, (25, 32), (32, 38), 0.93),
    "TILLEUL":       (6.6, 12, (24, 27), (27, 31), 0.94),
}
# Harvest realisation vs declarations, per year (2024 is the real -28 % French harvest year,
# FranceAgriMer Observatoire 2024; 2026 assumes a spring frost hitting acacia).
YEAR_YIELD = {2024: 0.80, 2025: 1.00, 2026: 0.90}
YEAR_VARIETY_YIELD = {(2026, "ACACIA"): 0.56}
RESALE_MARKUP = 1.45            # B2B resale price = bulk purchase price x 1.45
SUPPLY_TARGET = 1.16            # declarations sized to 110 % of demand (normal year)
FX_APPROX = {"EUR": 1.0, "HUF": 395.0, "RON": 4.97}  # only to price declarations in local currency
COUNTRY_CCY = {"FR": "EUR", "HU": "HUF", "RO": "RON"}

SEGMENTS = [("FOOD_PRODUCER", 0.40), ("HOSPITALITY", 0.30), ("COSMETICS", 0.15), ("PRIVATE_LABEL", 0.15)]
LABS = ["LAB_APINOV", "LAB_QUALIMEL"]

VARIETY_LABEL_VARIANTS = {
    "TOUTES_FLEURS": ["Toutes fleurs", "TOUTES FLEURS", "toutes_fleurs", "Multifloral", "toutes-fleurs "],
    "ACACIA": ["Acacia", "ACACIA", " acacia", "Acacia (robinier)", "Robinia"],
    "CHATAIGNIER": ["Chataignier", "Châtaignier", "CHATAIGNIER", "chestnut"],
    "LAVANDE": ["Lavande", "LAVANDE", "lavender", "Lavande "],
    "TOURNESOL": ["Tournesol", "TOURNESOL", "sunflower"],
    "COLZA": ["Colza", "COLZA", "rapeseed"],
    "MONTAGNE": ["Montagne", "MONTAGNE", "mountain"],
    "TILLEUL": ["Tilleul", "TILLEUL", "linden"],
}


def iso_week_str(d: dt.date) -> str:
    y, w, _ = d.isocalendar()
    return f"{y}-W{w:02d}"


def monday_of(year: int, week: int) -> dt.date:
    return dt.date.fromisocalendar(year, min(week, 52), 1)


class Issues:
    """Counts every defect injected on purpose = the answer key for the silver layer."""

    def __init__(self):
        self.counts = defaultdict(int)

    def add(self, source: str, kind: str, n: int = 1):
        self.counts[f"{source}.{kind}"] += n


class Sim:
    def __init__(self, seed: int, start: dt.date, end: dt.date, mess: float, apiaries_csv: Path):
        self.r = random.Random(seed)
        self.start, self.end, self.mess = start, end, mess
        self.issues = Issues()
        with open(apiaries_csv, newline="", encoding="utf-8") as f:
            self.apiaries = list(csv.DictReader(f))
        self._build_master_data()
        # state
        self.lots = {}                 # lot_id -> dict
        self.lot_seq = 0
        self.orders = {}               # order_line_id -> dict
        self.order_seq = 0
        self.decls = {}                # declaration_id -> dict
        self.decl_seq = 0
        self.hive_weight = {h["hive_id"]: 38.0 + self.r.random() * 8 for h in self.hives}
        self.hive_supers = {h["hive_id"]: 0.0 for h in self.hives}
        self.event_seq = 0
        self.daily = defaultdict(lambda: defaultdict(list))   # date -> source -> rows
        self.service = defaultdict(lambda: [0.0, 0.0])        # (year, variety) -> [ordered, shipped]

    # ---------------------------------------------------------------- master data
    def _build_master_data(self):
        r = self.r
        first = ["Jean", "Marie", "Luc", "Claire", "Paul", "Sophie", "Henri", "Lucie", "Marc", "Anne",
                 "Istvan", "Zsofia", "Andrei", "Ioana", "Pierre", "Elodie", "Hugo", "Camille", "Louis", "Lea"]
        last = ["Martin", "Bernard", "Roux", "Fabre", "Garnier", "Blanc", "Mercier", "Faure", "Rousseau",
                "Chevalier", "Nagy", "Kovacs", "Popescu", "Ionescu", "Girard", "Lambert", "Bonnet", "Dupuis"]
        self.beekeepers = []
        for i in range(1, 61):
            ap = self.apiaries[(i - 1) % len(self.apiaries)]
            fn, ln = r.choice(first), r.choice(last)
            self.beekeepers.append({
                "beekeeper_id": f"BK{i:03d}",
                "full_name": f"{fn} {ln}",
                "email": f"{fn.lower()}.{ln.lower()}{i}@rucher-mail.example",
                "phone": f"+33 6 {r.randint(10,99)} {r.randint(10,99)} {r.randint(10,99)} {r.randint(10,99)}",
                "iban": f"FR76 {r.randint(1000,9999)} {r.randint(1000,9999)} {r.randint(1000,9999)} {r.randint(1000,9999)} {r.randint(100,999)}",
                "apiary_id": ap["apiary_id"],
                "country_code": ap["country_code"],
                "currency": COUNTRY_CCY[ap["country_code"]],
                "hives_count": r.randint(60, 420),
                "is_organic": r.random() < 0.25,
                "reliability": round(r.uniform(0.78, 1.04), 3),   # hidden truth: delivered/declared
                "partner_since": dt.date(2015 + r.randint(0, 8), r.randint(1, 12), 1).isoformat(),
            })
        self.customers = []
        for i in range(1, 111):
            seg = r.choices([s for s, _ in SEGMENTS], [w for _, w in SEGMENTS])[0]
            n_var = r.choice([1, 1, 2, 2, 3])
            vars_ = r.sample(list(VARIETIES), n_var)
            self.customers.append({
                "customer_id": f"C{i:04d}",
                "company_name": f"{r.choice(['Biscuiterie', 'Hotel', 'Laboratoire', 'Maison', 'Confiserie', 'Brasserie', 'Epicerie'])} "
                                f"{r.choice(['du Lac', 'des Alpes', 'Saint-Louis', 'Lumiere', 'Belle Rive', 'du Moulin', 'Royale', 'Verte'])} {i}",
                "segment": seg,
                "country_code": r.choice(["FR"] * 8 + ["BE", "DE"]),
                "contact_email": f"achats{i}@client-{i}.example",
                "varieties": vars_,
                "created_at": dt.date(2019 + r.randint(0, 4), r.randint(1, 12), r.randint(1, 28)).isoformat(),
            })
        # B2B demand allocated per customer & variety (kg / year)
        self.contract_kg = {}
        for v, (_, demand_t, *_rest) in VARIETIES.items():
            buyers = [c for c in self.customers if v in c["varieties"]]
            weights = [r.uniform(0.3, 2.5) for _ in buyers]
            tot = sum(weights)
            for c, w in zip(buyers, weights):
                self.contract_kg[(c["customer_id"], v)] = demand_t * 1000 * w / tot
        self.hives = []
        for ap in self.apiaries:
            for k in (1, 2):
                self.hives.append({"hive_id": f"HV{ap['apiary_id'][2:]}{k}", "apiary_id": ap["apiary_id"],
                                   "varieties": ap["main_varieties"].split("|")})

    # ---------------------------------------------------------------- helpers
    def messy(self, p_scale=1.0) -> bool:
        return self.r.random() < self.mess * p_scale

    def new_lot(self, d, variety, kg, beekeeper_id, status="QUARANTINE"):
        self.lot_seq += 1
        lot_id = f"L{d:%y%m%d}{self.lot_seq:05d}"
        self.lots[lot_id] = {"lot_id": lot_id, "variety": variety, "received_date": d, "initial_kg": kg,
                             "kg_remaining": kg, "status": status, "beekeeper_id": beekeeper_id,
                             "lab_due": d + dt.timedelta(days=self.r.randint(3, 7)), "location": f"ZONE-{self.r.choice('ABCD')}{self.r.randint(1,20):02d}"}
        return lot_id

    # ---------------------------------------------------------------- simulation
    def run(self):
        r = self.r
        # opening stock: ~5 months of demand, already released
        for v, (_, demand_t, *_rest) in VARIETIES.items():
            remaining = demand_t * 1000 * 5 / 12
            while remaining > 0:
                kg = min(remaining, r.choice([300.0, 600.0, 1200.0]))
                lid = self.new_lot(self.start - dt.timedelta(days=r.randint(30, 120)), v, kg, "OPENING", "RELEASED")
                self.lots[lid]["lab_due"] = None
                remaining -= kg
        d = self.start
        while d <= self.end:
            self.day(d)
            d += dt.timedelta(days=1)

    def day(self, d: dt.date):
        r = self.r
        y, w, wd = d.isocalendar()
        out = self.daily[d]

        # 1) Beekeepers declare their expected harvest (each Monday of week 10 and week 20 of the year)
        if wd == 1 and w in (10, 20):
            for bk in self.beekeepers:
                ap = next(a for a in self.apiaries if a["apiary_id"] == bk["apiary_id"])
                for v in ap["main_varieties"].split("|"):
                    flow0, flow1 = VARIETIES[v][2]
                    if (w == 10 and flow0 > 22) or (w == 20 and flow0 <= 22):
                        continue  # each variety declared once: early varieties in week 10, late ones in week 20
                    n_bk = sum(1 for b in self.beekeepers if v in next(a for a in self.apiaries if a["apiary_id"] == b["apiary_id"])["main_varieties"])
                    target = VARIETIES[v][1] * 1000 * SUPPLY_TARGET / max(n_bk, 1)
                    declared = round(target * r.uniform(0.75, 1.25) / 10) * 10
                    d0, d1 = VARIETIES[v][3]
                    exp_week = r.randint(d0, d1)
                    price_eur = VARIETIES[v][0] * r.uniform(0.95, 1.08)
                    self.decl_seq += 1
                    dec = {"declaration_id": f"HD{self.decl_seq:05d}", "beekeeper_id": bk["beekeeper_id"], "variety": v,
                           "declared_kg": declared, "expected_week": f"{y}-W{exp_week:02d}",
                           "price_per_kg": round(price_eur * FX_APPROX[bk["currency"]], 2), "currency": bk["currency"],
                           "declared_at": d, "status": "OPEN", "delivered_kg": 0.0, "updated_at": d,
                           "_deliver_on": monday_of(y, exp_week) + dt.timedelta(days=r.randint(0, 4) + 7 * r.choice([-1, 0, 0, 1]))}
                    if r.random() < 0.03:
                        dec["_cancel"] = True
                    self.decls[dec["declaration_id"]] = dec
                    out["harvest_declarations"].append(self.decl_row(dec))

        # 2) Deliveries of declared honey -> new lots in quarantine
        for dec in self.decls.values():
            if dec["status"] != "OPEN" or dec["_deliver_on"] != d:
                continue
            if dec.get("_cancel"):
                dec["status"], dec["updated_at"] = "CANCELLED", d
                out["harvest_declarations"].append(self.decl_row(dec))
                continue
            bk = next(b for b in self.beekeepers if b["beekeeper_id"] == dec["beekeeper_id"])
            yf = YEAR_VARIETY_YIELD.get((y, dec["variety"]), YEAR_YIELD.get(y, 0.95))
            delivered = round(dec["declared_kg"] * yf * bk["reliability"] * r.uniform(0.92, 1.06), 1)
            remaining = delivered
            while remaining > 0:   # one drum-lot per 300 kg (a 300 kg drum is the standard bulk unit)
                kg = min(300.0, remaining)
                self.new_lot(d, dec["variety"], kg, bk["beekeeper_id"])
                remaining = round(remaining - kg, 1)
            dec.update(status="DELIVERED", delivered_kg=delivered, updated_at=d)
            out["harvest_declarations"].append(self.decl_row(dec))

        # 3) Lab results for lots whose analysis is due today
        for lot in self.lots.values():
            if lot["status"] == "QUARANTINE" and lot["lab_due"] == d:
                passed = r.random() < VARIETIES[lot["variety"]][4]
                lot["status"] = "RELEASED" if passed else "BLOCKED"
                out["lab_results"].append(self.lab_row(lot, passed, d))

        # 4) New B2B call-off orders (monthly per contract, created 2-10 weeks ahead)
        for (cid, v), kg_year in self.contract_kg.items():
            if r.random() < 12 / 365:
                qty = round(kg_year / 12 * r.uniform(0.6, 1.4) * (1.2 if d.month in (10, 11) else 1.0) / 10) * 10
                if qty < 20:
                    continue
                self.order_seq += 1
                ol = {"order_line_id": f"OL{self.order_seq:06d}", "order_id": f"SO{self.order_seq // 2 + 100000}",
                      "customer_id": cid, "variety": v, "quantity_kg": float(qty),
                      "unit_price_eur": round(VARIETIES[v][0] * RESALE_MARKUP * r.uniform(0.95, 1.08), 2),
                      "requested_delivery_date": d + dt.timedelta(days=r.randint(14, 70)),
                      "status": "CONFIRMED", "shipped_kg": 0.0, "created_at": d, "updated_at": d, "channel": "B2B"}
                self.orders[ol["order_line_id"]] = ol
                out["erp_order_lines"].append(self.order_row(ol))
        # small B2C webshop flow, one aggregated line per day (excluded from the B2B metric)
        if r.random() < 0.9:
            v = r.choice(list(VARIETIES))
            self.order_seq += 1
            ol = {"order_line_id": f"OL{self.order_seq:06d}", "order_id": f"WEB{self.order_seq}", "customer_id": "C0000",
                  "variety": v, "quantity_kg": float(r.randint(5, 60)), "unit_price_eur": round(VARIETIES[v][0] * 3.0, 2),
                  "requested_delivery_date": d + dt.timedelta(days=3), "status": "CONFIRMED", "shipped_kg": 0.0,
                  "created_at": d, "updated_at": d, "channel": "B2C_WEBSHOP"}
            self.orders[ol["order_line_id"]] = ol
            out["erp_order_lines"].append(self.order_row(ol))

        # 5) Amendments / cancellations of open orders (they make the export incremental, not append-only)
        for ol in self.orders.values():
            if ol["status"] == "CONFIRMED" and ol["created_at"] < d and ol["channel"] == "B2B":
                if r.random() < 0.0025:
                    ol["status"], ol["updated_at"] = "CANCELLED", d
                    out["erp_order_lines"].append(self.order_row(ol))
                elif r.random() < 0.004:
                    ol["quantity_kg"], ol["updated_at"] = float(round(ol["quantity_kg"] * r.uniform(0.7, 1.3) / 10) * 10), d
                    out["erp_order_lines"].append(self.order_row(ol))

        # 6) Shipments FIFO from released stock on the requested date
        due = sorted([o for o in self.orders.values() if o["status"] == "CONFIRMED" and o["requested_delivery_date"] == d],
                     key=lambda o: o["order_line_id"])
        for ol in due:
            need = ol["quantity_kg"]
            for lot in sorted([l for l in self.lots.values() if l["variety"] == ol["variety"] and l["status"] == "RELEASED" and l["kg_remaining"] > 0],
                              key=lambda l: (l["received_date"], l["lot_id"])):
                take = min(need, lot["kg_remaining"])
                lot["kg_remaining"] = round(lot["kg_remaining"] - take, 1)
                if lot["kg_remaining"] <= 0:
                    lot["status"] = "EMPTY"
                need = round(need - take, 1)
                if need <= 0:
                    break
            ol["shipped_kg"] = round(ol["quantity_kg"] - need, 1)
            ol["status"] = "SHIPPED" if need <= 0 else ("PARTIALLY_SHIPPED" if ol["shipped_kg"] > 0 else "BACKORDER_LOST")
            ol["updated_at"] = d
            if ol["channel"] == "B2B":
                s = self.service[(d.year, ol["variety"])]   # calendar year, like the gold model
                s[0] += ol["quantity_kg"]
                s[1] += ol["shipped_kg"]
            out["erp_order_lines"].append(self.order_row(ol))

        # 7) Daily WMS snapshot (lots with stock or in quarantine)
        for lot in self.lots.values():
            if lot["status"] in ("QUARANTINE", "RELEASED", "BLOCKED") and lot["kg_remaining"] > 0:
                out["wms_stock"].append(self.wms_row(lot, d))

        # 8) Hive scale telemetry (every 4 hours)
        for h in self.hives:
            in_flow = [v for v in h["varieties"] if VARIETIES[v][2][0] <= w <= VARIETIES[v][2][1]]
            yf = min(YEAR_VARIETY_YIELD.get((y, v), YEAR_YIELD.get(y, 0.95)) for v in h["varieties"]) if in_flow else 1
            if in_flow:
                gain = max(0.0, r.gauss(1.1 * yf, 0.6))
                self.hive_supers[h["hive_id"]] += gain
            else:
                gain = -abs(r.gauss(0.08 if w < 10 or w > 44 else 0.15, 0.05))
            # harvest: supers removed the week after the flow ends
            if any(VARIETIES[v][2][1] + 1 == w for v in h["varieties"]) and wd == 2 and self.hive_supers[h["hive_id"]] > 0:
                gain -= self.hive_supers[h["hive_id"]]
                self.hive_supers[h["hive_id"]] = 0.0
            self.hive_weight[h["hive_id"]] = max(25.0, self.hive_weight[h["hive_id"]] + gain)
            for hour in (2, 6, 10, 14, 18, 22):
                self.event_seq += 1
                ts = dt.datetime(d.year, d.month, d.day, hour, r.randint(0, 59), r.randint(0, 59), tzinfo=dt.timezone.utc)
                ev = {"event_id": f"EV{self.event_seq:09d}", "hive_id": h["hive_id"], "apiary_id": h["apiary_id"],
                      "ts": ts.isoformat().replace("+00:00", "Z"),
                      "weight_kg": round(self.hive_weight[h["hive_id"]] + (0.4 if 10 <= hour <= 18 else 0) * (1 if in_flow else 0) + r.gauss(0, 0.15), 2),
                      "temp_internal_c": round(r.gauss(34.5 if 12 <= w <= 40 else 22, 1.5), 1),
                      "humidity_pct": round(r.uniform(45, 75), 1), "battery_v": round(r.uniform(3.6, 4.1), 2), "fw": "2.3.1"}
                if self.messy(0.4):
                    ev["ts"] = int(ts.timestamp()); self.issues.add("hive_events", "epoch_timestamp")
                if self.messy(0.15):
                    ev["weight_kg"] = 0.0; self.issues.add("hive_events", "sensor_zero_weight")
                if self.messy(0.15):
                    ev["WEIGHT"] = ev.pop("weight_kg"); self.issues.add("hive_events", "renamed_key_WEIGHT")
                out["hive_events"].append(ev)
                if self.messy(0.5):   # Pub/Sub is at-least-once: the same message can arrive twice
                    out["hive_events"].append(dict(ev)); self.issues.add("hive_events", "duplicate_event")

        # weekly master-data snapshots
        if wd == 1 or d == self.start:
            out["beekeepers"] = [self.beekeeper_row(b) for b in self.beekeepers]
            out["erp_customers"] = [self.customer_row(c) for c in self.customers]

    # ---------------------------------------------------------------- row writers (inject mess)
    def fmt_date(self, d: dt.date, source: str) -> str:
        if self.messy(0.5):
            self.issues.add(source, "non_iso_date")
            return self.r.choice([d.strftime("%d/%m/%Y"), d.strftime("%Y%m%d"), d.strftime("%d %b %Y")])
        return d.isoformat()

    def variety_label(self, v: str, source: str) -> str:
        if self.messy(1.5):
            self.issues.add(source, "variety_label_variant")
            return self.r.choice(VARIETY_LABEL_VARIANTS[v])
        return v

    def order_row(self, ol):
        row = {k: v for k, v in ol.items()}
        row["variety"] = self.variety_label(ol["variety"], "erp_order_lines")
        row["requested_delivery_date"] = self.fmt_date(ol["requested_delivery_date"], "erp_order_lines")
        row["created_at"] = ol["created_at"].isoformat() + "T08:00:00+01:00"
        # versions of a line are emitted in business order (created -> amended -> shipped): the timestamp must follow
        # that order, otherwise "latest version wins" would pick the wrong one (found by the answer-key reconciliation)
        ol["_v"] = ol.get("_v", 0) + 1
        row.pop("_v", None)
        row["updated_at"] = ol["updated_at"].isoformat() + f"T{8 + min(ol['_v'], 11):02d}:{self.r.randint(0, 59):02d}:00+01:00"
        if self.messy(0.4):
            row["quantity_kg"] = f"{row['quantity_kg']:,.1f}".replace(",", " ").replace(".", ",")
            self.issues.add("erp_order_lines", "quantity_as_french_text")
        if self.messy(0.2):
            row["status"] = row["status"].lower() + " "
            self.issues.add("erp_order_lines", "status_case_space")
        return row

    def decl_row(self, dec):
        row = {k: v for k, v in dec.items() if not k.startswith("_")}
        row["variety"] = self.variety_label(dec["variety"], "harvest_declarations")
        row["declared_at"] = self.fmt_date(dec["declared_at"], "harvest_declarations")
        row["updated_at"] = dec["updated_at"].isoformat()
        if self.messy(0.3):
            row["declared_kg"] = f"{dec['declared_kg']} kg"; self.issues.add("harvest_declarations", "kg_with_unit")
        return row

    def lab_row(self, lot, passed, d):
        moisture = round(self.r.uniform(15.5, 18.4) if passed else self.r.uniform(18.6, 21.0), 1)
        hmf = round(self.r.uniform(2, 25) if passed else self.r.uniform(30, 55), 1)
        row = {"sample_id": f"S{lot['lot_id'][1:]}", "lot_id": lot["lot_id"], "lab_name": self.r.choice(LABS),
               "analysis_date": self.fmt_date(d, "lab_results"), "declared_variety": self.variety_label(lot["variety"], "lab_results"),
               "moisture_pct": str(moisture), "hmf_mg_kg": str(hmf), "pollen_origin_match": "Y" if passed or self.r.random() < 0.5 else "N",
               "c4_sugar_pct": str(round(self.r.uniform(0, 3) if passed else self.r.uniform(0, 12), 1)),
               "verdict": "PASS" if passed else "FAIL"}
        if self.messy(0.6):
            row["moisture_pct"] = row["moisture_pct"].replace(".", ",") + " %"; self.issues.add("lab_results", "moisture_text_percent")
        if self.messy(0.6):
            row["verdict"] = self.r.choice(["Conforme", "pass", "OK"] if passed else ["Non conforme", "fail", "KO"])
            self.issues.add("lab_results", "verdict_label_variant")
        if self.messy(0.6):
            row["pollen_origin_match"] = self.r.choice(["yes", "1", "TRUE"] if row["pollen_origin_match"] == "Y" else ["no", "0", "false"])
            self.issues.add("lab_results", "boolean_variant")
        return row

    def wms_row(self, lot, d):
        return {"snapshot_date": d.isoformat(), "lot_id": lot["lot_id"], "variety": lot["variety"], "location": lot["location"],
                "kg_remaining": lot["kg_remaining"], "status": lot["status"], "received_date": lot["received_date"].isoformat(),
                "supplier_id": lot["beekeeper_id"]}

    def beekeeper_row(self, b):
        return {k: v for k, v in b.items() if k != "reliability"}

    def customer_row(self, c):
        row = {k: v for k, v in c.items() if k != "varieties"}
        row["main_varieties"] = "|".join(c["varieties"])
        return row

    # ---------------------------------------------------------------- truth for reconciliation
    def answer_key(self):
        released = defaultdict(float)
        quarantine = defaultdict(float)
        for lot in self.lots.values():
            if lot["status"] == "RELEASED":
                released[lot["variety"]] += lot["kg_remaining"]
            elif lot["status"] == "QUARANTINE":
                quarantine[lot["variety"]] += lot["kg_remaining"]
        open_b2b = defaultdict(float)
        for o in self.orders.values():
            if o["status"] == "CONFIRMED" and o["channel"] == "B2B":
                open_b2b[o["variety"]] += o["quantity_kg"]
        return {
            "as_of_date": self.end.isoformat(),
            "true_released_stock_kg": {k: round(v, 1) for k, v in sorted(released.items())},
            "true_quarantine_stock_kg": {k: round(v, 1) for k, v in sorted(quarantine.items())},
            "true_open_b2b_demand_kg": {k: round(v, 1) for k, v in sorted(open_b2b.items())},
            "service_level_by_year": {f"{y}": round(sum(s[1] for (yy, _), s in self.service.items() if yy == y) /
                                                     max(1, sum(s[0] for (yy, _), s in self.service.items() if yy == y)), 4)
                                      for y in sorted({y for y, _ in self.service})},
            "injected_issues": dict(sorted(self.issues.counts.items())),
        }


# ------------------------------------------------------------------------------------------
def write_day(base: Path, d: dt.date, rows_by_source: dict):
    part = f"dt={d.isoformat()}"
    for source, rows in rows_by_source.items():
        if not rows:
            continue
        folder = base / source / part
        folder.mkdir(parents=True, exist_ok=True)
        stamp = d.strftime("%Y%m%d")
        if source in ("erp_order_lines", "hive_events"):
            with open(folder / f"{source}_{stamp}.jsonl", "w", encoding="utf-8") as f:
                for row in rows:
                    f.write(json.dumps(row, default=str, ensure_ascii=False) + "\n")
        elif source == "lab_results":
            for lab in LABS:
                lab_rows = [r for r in rows if r["lab_name"] == lab]
                if lab_rows:
                    _csv(folder / f"lab_results_{lab.lower()}_{stamp}.csv", lab_rows)
        else:
            _csv(folder / f"{source}_{stamp}.csv", rows)


def _csv(path: Path, rows: list):
    keys = list(rows[0].keys())
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", default="data/landing")
    p.add_argument("--start", default="2024-01-01")
    p.add_argument("--end", default=dt.date.today().isoformat())
    p.add_argument("--only-date", help="write only this day's increment (the simulation still replays from --start)")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--mess", type=float, default=0.02, help="base probability of a damaged field")
    p.add_argument("--apiaries", default=str(Path(__file__).resolve().parent.parent / "config" / "apiaries.csv"))
    a = p.parse_args()
    start = dt.date.fromisoformat(a.start)
    end = dt.date.fromisoformat(a.only_date or a.end)
    sim = Sim(a.seed, start, end, a.mess, Path(a.apiaries))
    sim.run()
    base = Path(a.out)
    days = [dt.date.fromisoformat(a.only_date)] if a.only_date else sorted(sim.daily)
    for d in days:
        write_day(base, d, sim.daily[d])
    key = sim.answer_key()
    (base.parent / "answer_key.json").write_text(json.dumps(key, indent=2))
    print(json.dumps({"days_written": len(days), "service_level_by_year": key["service_level_by_year"]}, indent=2))


if __name__ == "__main__":
    main()
