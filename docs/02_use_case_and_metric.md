# 02 · Use case and metric definition

> Criterion C2: identified decision and user, metric with grain/formula/exclusions, justified frequency, acceptance test.

## 1. Use case UC1: supply coverage

**Question:** *"Will we have enough lab-approved honey to serve our B2B contracts in each of the next 8 weeks, variety by variety, and if not, what should we do?"*

| | |
|---|---|
| **Decision** | Per variety: do nothing / watch / buy from partner beekeepers' stock / spot import and renegotiate delivery dates. |
| **User** | Head of Sourcing. Weekly review on Monday at 08:00, plus an e-mail alert the day a variety turns RED. |
| **Output** | `GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY` (detail), `GOLD.GOLD_COVERAGE_ACTIONS` (one line per variety), Streamlit cockpit, alert `A_COVERAGE_RED`. |
| **Business outcome** | B2B service level ≥ 95 % (measured in `GOLD.FCT_SERVICE_LEVEL_MONTHLY`). |

## 2. Metric: coverage ratio

**Grain:** one row per `as_of_date` × `variety_code` × `week_number` (1 to 8 = the 8 ISO weeks after the decision date).

```
supply_at_start(v)    = released_kg(v) + pending_lab_kg(v) × pass_rate(v)
cum_supply(v, w)      = supply_at_start(v) + Σ_{k ≤ w} expected_intake_kg(v, k)
cum_demand(v, w)      = Σ_{k ≤ w} [ b2b_demand_kg(v, k) + b2c_reserve_kg(v) ]
coverage_ratio(v, w)  = cum_supply(v, w) / cum_demand(v, w)
shortfall_kg(v, w)    = max(cum_demand − cum_supply, 0)
status                = RED if ratio < 0.90 · AMBER if 0.90 ≤ ratio < 1.10 · GREEN if ratio ≥ 1.10
```

| Component | Definition | Source |
|---|---|---|
| `released_kg` | kg of lots with status RELEASED in the WMS snapshot of the decision date | WMS |
| `pending_lab_kg` | kg of lots in QUARANTINE (received, analysis pending) | WMS |
| `pass_rate` | share of lab verdicts PASS for the variety over the last 365 days (default 0.90 if < 20 results) | LIMS |
| `expected_intake_kg` | Σ OPEN harvest declarations expected that week × beekeeper reliability (delivered/declared, 365 d) × flow factor of his apiary | portal + hive scales + **Open-Meteo** + **GBIF** |
| `b2b_demand_kg` | max(confirmed B2B lines for delivery that week, 13-week average weekly B2B volume). Overdue confirmed lines go to week 1 | ERP |
| `b2c_reserve_kg` | average weekly webshop volume over the last 8 weeks | ERP |

**Why cumulative?** Stock carries over from one week to the next. A deficit in week 3 is a deficit in weeks 3 to 8 unless new honey arrives.

**Why the max with a baseline?** Customers call off 2 to 10 weeks ahead, so the confirmed order book always looks empty beyond week 4. Without the baseline, weeks 5 to 8 would always look GREEN (a false sense of safety).

### Exclusions (and why)

| Excluded | Why |
|---|---|
| CANCELLED and SHIPPED order lines | not demand any more |
| BLOCKED lots (failed lab) and EMPTY lots | not sellable |
| Rows in `SILVER.QUARANTINE` (unknown variety, invalid quantity, sensor faults…) | cannot be trusted; listed for the data owner |
| B2C orders from the B2B demand | B2C is protected by a reserve, not a contract |
| Hive readings ≤ 5 kg, and daily drops > 5 kg (harvest) | sensor fault or manipulation, not a nectar signal |

### Valuation (decision support)

`partner_price_eur_kg` = average declared price over 365 days, converted with the **real ECB rate** of the declaration day (HUF and RON partners), × 1.05. `spot_price_eur_kg` = **real Eurostat** EU honey import unit value (last 3 months) × variety premium (**FranceAgriMer** price / multifloral price) × 1.12.

Recommended action: first RED week ≥ 4 weeks away → **buy from partner stock** (traceable, ~2 weeks of lead time). First RED week < 4 weeks away → **spot import + renegotiate delivery dates**.

## 3. Frequency (justified)

- **Decision**: weekly. Purchasing negotiates in weekly cycles, and lead times are 2 to 4 weeks.
- **Refresh**: daily batch at 06:30 (Paris). Orders and stock change every day, and the alert must fire the morning a variety turns RED, not up to 6 days later. Daily is the cheapest frequency that meets this (~5 min of XS warehouse).
- **Not real-time.** Nobody buys honey at 3 pm because of a 2 pm reading. The hive scales report every 4 h and are loaded by Snowpipe as soon as they land; a separate freshness alert watches them every 2 h. Real-time adds no value to *this* decision, so we do not invent a streaming requirement for it.

## 4. Today's output (decision date 2026-11-01, run on Snowflake on 2 Nov 2026)

| Variety | Status | First RED week | Shortfall at W+8 | Action | Partner option | Spot option |
|---|---|---|---|---|---|---|
| ACACIA | **RED** | 2026-W48 (W+4) | 3,454 kg | BUY FROM PARTNER STOCK | €27.4 k | €13.0 k (real Eurostat import price) |
| the 7 others | GREEN | – | 0 | OK – no action | – | – |

The local DuckDB run gives the same status and shortfall; only the spot price differs (€14.0 k locally, where the Eurostat API is replaced by a fixture).

## 5. Acceptance test

1. **Formula (dbt unit test `coverage_formula_acceptance_test`)**. Hand-computed case: 3,000 kg released + 1,000 kg pending at 90 % pass = 3,900 kg.

   | Week | Intake | Demand + B2C | Cumulative supply | Cumulative demand | Expected ratio / status / shortfall |
   |---|---|---|---|---|---|
   | 1 | 0 | 2,100 | 3,900 | 2,100 | 1.857 · GREEN · 0 |
   | 2 | 500 | 2,100 | 4,400 | 4,200 | 1.048 · AMBER · 0 |
   | 3 | 0 | 2,000 | 4,400 | 6,200 | 0.710 · RED · 1,800 |

   The test runs in every `dbt build`. If the model deviates by one kg, the build fails.

2. **Reconciliation with known data** (`scripts/verify_against_answer_key.py`, output in `docs/evidence/verification_vs_answer_key.txt`). Released stock, open order book and yearly service level in GOLD equal the truth of the simulation **to the kg**, and every injected defect is accounted for.

3. **Backtest.** Replaying the decision of **Monday 30 March 2026** (`dbt build --vars '{as_of_date: "2026-03-30"}'`): the varieties flagged RED are the ones that actually ran short in April-May 2026, and the GREEN varieties were served. Detail in the evidence file.

4. **Dbt singular tests on every run:** released stock in GOLD = Σ RELEASED lots of the WMS snapshot (`assert_released_stock_reconciles_with_wms`), and the horizon is complete with 64 rows (`assert_horizon_is_complete`).

**Accepted when:** 1, 2 and 4 pass, and the Head of Sourcing confirms on the backtest that the flagged varieties match her memory of spring 2026.

## 6. Limitations (stated on the slides)

- Internal systems are **simulated** (realistic and messy, seeded generator). The 5 external sources are real.
- Off-season (November), no harvest is expected, so the forecast rests on stock and demand only. The flow signals matter from April to September (see the backtest).
- The flow-index weights (50/30/20) are an assumption; they need to be recalibrated on one real season.
- The demand baseline does not model seasonality (Q4 gifting peak). A seasonal baseline is the next improvement.
