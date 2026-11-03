# 01 · Business case: BeeG's, "Honey with a groove"

> Criterion C1: a convincing fictional company. Every number here is either **real (sourced)** or an **explicit assumption** (marked *A-n*). The simulated internal data reproduces these assumptions, so the figures on the slides can be recomputed from GOLD.

## 1. The company

| | |
|---|---|
| **What** | Traceable honey trader. We buy bulk honey from a network of partner beekeepers, have every lot tested by a lab, store it and resell it, mostly B2B. |
| **Where** | HQ and warehouse in Mâcon (Saône-et-Loire, FR). Partner apiaries in 8 French regions, plus Hungary (acacia) and Romania. |
| **Founded** | 2021. 12 employees: 2 buyers, 1 quality manager, 3 warehouse staff, 3 sales/account managers, 1 webshop/marketing, 2 data/finance. |
| **Suppliers** | 60 partner beekeepers (all with > 50 hives), 14,400 hives in total, 12 apiary sites (`config/apiaries.csv`). |
| **Customers** | 110 B2B accounts: food producers (40 %), hospitality (30 %), cosmetics (15 %), private label (15 %). Plus a webshop (B2C). |
| **Volume** | ~176 t/year sold B2B and ~9-10 t B2C (2024-2025, `gold.fct_order_lines`). |
| **Revenue** | ~€1.7 M/year: €1.55 M B2B (~89 %) + €0.17-0.19 M B2C (~11 %). Target split from the business model: 80/20 (*A-1*). |
| **Margin** | B2B resale price = bulk purchase price × 1.45 → ~31 % gross margin (*A-2*). |
| **Products** | 8 varieties: toutes fleurs, acacia, châtaignier, lavande, tournesol, colza, montagne, tilleul. Bulk drums of 300 kg for B2B, jars and gift sets for B2C. |

### Revenue model (business model canvas, slide 2)

- **Value proposition**: traceable honey with documented origin and lab-verified quality; flexible supply for businesses; reusable packaging.
- **Revenue streams**: bulk honey supply, repeat B2B orders under **seasonal supply agreements** (monthly call-offs), private label, B2C jars and gifts, beeswax co-products.
- **Cost structure**: honey purchase (~69 % of revenue), lab tests, filling and packaging, storage and delivery, container collection and cleaning.

## 2. The problem

Honey is harvested **once a year** (April to September) but sold **every week of the year**. BeeG's commits its B2B customers to monthly call-offs **months before** knowing how much honey the beekeepers will actually deliver, and before the lab has approved it.

**Real context (sourced):** French production fell to **21,585 t in 2024, -28 % vs 2023**, and the average yield per hive dropped from 22.5 kg to **15.2 kg** (FranceAgriMer, *Observatoire de la production de miel et gelée royale 2024*). Bulk prices in 2024: lavande €8.5/kg, montagne €7.7, acacia €7.4, châtaignier €7.1, tilleul €6.6, toutes fleurs €4.6, colza €4.1, tournesol €4.0.

**At BeeG's (simulated history, `gold.fct_service_level_monthly`):**

| Year | B2B service level (kg shipped on time / kg ordered) | B2B revenue not served |
|---|---|---|
| 2024 | 96.8 % | €55 k |
| **2025** | **84.6 %** (the poor 2024 harvest ran out in spring 2025) | **€294 k** |
| 2026 (to 1 Nov) | 95.8 % | €75 k |

In 2025, **1 kg out of 6 ordered was not delivered on time**. Châtaignier (€103 k), tournesol (€60 k) and lavande (€42 k) were the worst. The buyers saw it too late: shortfalls were discovered when the warehouse could not ship, and at that point the only options were expensive spot imports (when available) or disappointed customers.

**Why it happened:** the information exists, but it sits in 6 systems that nobody combines. Stock is in the WMS, lab verdicts in the LIMS, commitments in the ERP and expected harvests in the beekeeper portal. The nectar-flow signals (hive scales, weather, flowering) are not used at all.

## 3. Numerical constraints and explicit assumptions

| # | Assumption / constraint | Value | Where it is used |
|---|---|---|---|
| A-1 | Revenue split target | 80 % B2B / 20 % B2C | business model |
| A-2 | Resale markup | × 1.45 on bulk price | generator, `revenue_at_risk_eur` |
| A-3 | Harvest realised vs declared | 2024: 0.80, 2025: 1.00, 2026: 0.90; acacia 2026: 0.56 (spring frost) | generator |
| A-4 | Beekeeper reliability | 0.78-1.04 delivered/declared, hidden truth per beekeeper | generator; *estimated* in `int_beekeeper_reliability` |
| A-5 | Lab pass rate | 90-96 % depending on variety (EU limits: moisture ≤ 20 %, HMF ≤ 40 mg/kg) | generator; *measured* in `int_lab_pass_rate` |
| A-6 | Customers call off 2-10 weeks ahead | order book incomplete beyond ~4 weeks | `int_demand_weekly` (13-week baseline) |
| A-7 | Partner stock purchase | partner price + 5 %, lead time ~2 weeks | `int_price_references`, action rule |
| A-8 | Spot import | Eurostat import unit value × variety premium × 1.12 landed cost, lead time ~4 weeks, less traceable | `int_price_references`, action rule |
| A-9 | Decision rhythm | weekly (Monday 08:00), 8-week horizon | `gold_supply_coverage_weekly` |
| A-10 | Flow index weights | hive scales 50 %, weather 30 %, bloom 20 % | `int_apiary_flow_weekly` (to recalibrate after one real season) |

## 4. Stakeholders

| Who | Role in the project |
|---|---|
| **Head of Sourcing** (decision owner) | Every Monday decides what to buy, from whom, or which delivery dates to renegotiate. Main user of the dashboard and recipient of the RED alert. |
| Quality manager | Owns lab results; is alerted when a lab file is broken (INC-002). |
| Account managers | Renegotiate delivery dates with customers when the action says so. |
| Partner beekeepers | Declare their expected harvest in the portal; their contact details are personal data (masked). |
| Data team (us, 4 people) | Build and run the platform. |

## 5. Expected value

If the shortfall is seen **≥ 4 weeks ahead**, BeeG's can buy traceable honey from partner beekeepers' stock (France held 13,222 t of unsold stock at the end of 2024, FranceAgriMer) instead of losing the sale. **Target:** bring the B2B service level back above 95 % in a poor-harvest year. Recovering even half of the 2025 loss is **~€147 k of revenue / ~€45 k of gross margin**, against a platform that costs **~€25/month** to run (docs/07).
