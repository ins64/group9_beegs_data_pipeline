# 04 · Data model and lineage (dbt)

> Criteria C3 (working transformations), C4 (dbt mandatory), documentation. The same descriptions live in the dbt YAML files
> (`models/*/_*.yml`) and are pushed to Snowflake as table and column comments (`persist_docs`), so Snowsight shows them too.

## 1. Layers

| Layer | Schema | Built by | Materialisation | Rule |
|---|---|---|---|---|
| Bronze | `BEEGS.BRONZE` | `COPY INTO` (task graph) and Snowpipe | tables, append only | data exactly as received + `_source_file`, `_file_row_number`, `_loaded_at`; never modified |
| Silver: staging | `BEEGS.SILVER` | dbt `stg_*` | views, or incremental tables for the 3 big sources | typing, cleaning, de-duplication (latest `_loaded_at` wins), `reject_reason` |
| Silver: quarantine | `BEEGS.SILVER.QUARANTINE` | dbt `quarantine` | table | every rejected row with its source, key and reason; nothing is dropped silently |
| Silver: intermediate | `BEEGS.SILVER` | dbt `int_*` | views / tables | business rules and as-of logic (what was known on the decision date) |
| Gold | `BEEGS.GOLD` | dbt marts | tables, `gold_supply_coverage_weekly` incremental (merge on `as_of_date`) | consumer tables; `SELECT` granted to `BEEGS_PURCHASING` and `BEEGS_ANALYST` by a dbt post-hook |

Lineage: `dbt docs generate` (model level) and Snowsight → table → *Lineage* (column level).

## 2. Staging models (one per source)

| Model | Source | Grain | Main cleaning |
|---|---|---|---|
| `stg_erp__order_lines` | ERP (JSONL, changed rows) | order line (latest version) | 4 date formats, French decimal text, status case/spaces, 20 spellings of the variety, incremental MERGE |
| `stg_erp__customers` | ERP (CSV snapshot) | customer | latest snapshot |
| `stg_portal__beekeepers` | beekeeper portal (PII) | beekeeper | contact data kept for masking; IBAN stays in bronze |
| `stg_portal__harvest_declarations` | beekeeper portal | declaration (latest) | "kg" units in numbers, dates, variety labels |
| `stg_lims__lab_results` | 2 labs (CSV per lab per day) | sample (latest load) | verdict vocabulary (`lab_verdict_map` seed), "16.2%" text, booleans; reject-share gate |
| `stg_wms__stock_snapshots` | WMS (full daily snapshot) | lot × snapshot date | incremental MERGE (333 k rows) |
| `stg_iot__hive_events` | hive scales (JSON every 4 h) | event | epoch / ISO timestamps, renamed key `WEIGHT`, duplicates removed on `event_id`, 0-kg readings quarantined; incremental |
| `stg_meteo__weather_daily` | Open-Meteo archive (REAL) | apiary × day (latest extraction) | JSON arrays flattened; overlap re-reads handled |
| `stg_meteo__weather_forecast` | Open-Meteo forecast (REAL) | apiary × day | latest run |
| `stg_ecb__fx_rates` | Frankfurter / ECB (REAL) | currency × day | |
| `stg_gbif__bloom_monthly` | GBIF (REAL) | plant × country × month | |
| `stg_eurostat__honey_imports` | Eurostat Comext (REAL) | origin × month | € and 100 kg → €/kg |

## 3. Intermediate models (business logic)

| Model | What it computes |
|---|---|
| `int_order_lines_asof`, `int_declarations_asof` | order book and declarations **as known on the decision date** (enables backtests) |
| `int_lab_pass_rate` | pass rate per variety over 365 days (0.90 by default below 20 results) |
| `int_beekeeper_reliability` | delivered / declared kg per beekeeper (capped at 1.2, default 0.90) |
| `int_hive_daily` | median weight per hive and day, daily gain (harvest drops excluded) |
| `int_apiary_flow_weekly` | nectar-flow index: hive scales 50 %, weather 30 %, GBIF bloom 20 % |
| `int_flow_factor_asof` | season flow factor applied to open declarations (1.0 if no signal) |
| `int_horizon_weeks` | the 8 ISO weeks after the decision date |
| `int_supply_position` | released, pending-lab and blocked kg per variety |
| `int_expected_intake_weekly` | open declarations × reliability × flow factor, per horizon week |
| `int_demand_weekly` | max(confirmed B2B, 13-week baseline) + B2C reserve |
| `int_price_references` | partner price (ECB FX) and spot import price (Eurostat + FranceAgriMer premium) |

## 4. Gold (what the business reads)

| Table | Grain | Used by |
|---|---|---|
| `gold_supply_coverage_weekly` | as_of_date × variety × week (8 weeks) | Streamlit heatmap, alert `A_COVERAGE_RED`, backtest |
| `gold_coverage_actions` | variety (latest decision) | recommended action and cost of each option |
| `fct_service_level_monthly` | month × variety | the problem chart, measuring the outcome of past decisions |
| `fct_order_lines` | order line | analysts |
| `dim_beekeeper` (PII masked), `dim_customer`, `dim_variety` | | joins, dashboard |
| `gold_apiary_signals` | apiary × variety | map / signals tab |
| `gold_pipeline_health` | source | freshness tile |

## 5. Tests (79 in one `dbt build`)

- **Generic**: `unique`, `not_null`, `relationships`, `accepted_values`, plus our own `unique_combination`, `non_negative` and `recent_reject_share` (fails if > 50 % of a single file or > 5 % overall is rejected; it sits **upstream of gold**, so a broken file stops gold from being rebuilt: INC-002).
- **Singular**: released stock in gold = Σ released lots of the WMS snapshot; horizon complete (64 rows = 8 varieties × 8 weeks); EU limits on lab results.
- **Unit test** `coverage_formula_acceptance_test`: the coverage formula on a case computed by hand.
- **Source freshness** thresholds declared per source rhythm; not run by the daily pipeline.

## 6. Seeds

`honey_varieties.csv` (8 varieties, seasons, FranceAgriMer 2024 prices), `variety_label_map.csv` (20 spellings → 8 codes), `lab_verdict_map.csv`, `apiaries.csv` (12 sites with coordinates). Versioned in Git and reviewed in pull requests.
