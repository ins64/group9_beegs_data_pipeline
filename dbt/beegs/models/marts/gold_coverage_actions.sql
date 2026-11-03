{#-
  One row per variety for the LATEST decision date: what the Head of Sourcing should do this week.
  Rule (agreed with the business, docs/02_use_case_and_metric.md):
    no RED week in the horizon, no AMBER  -> 'OK - no action'
    AMBER only                            -> 'WATCH - re-check next Monday'
    first RED week >= 4 weeks away        -> 'BUY FROM PARTNER STOCK' (traceable FR/EU honey, ~2 weeks lead time)
    first RED week <  4 weeks away        -> 'SPOT IMPORT + RENEGOTIATE DELIVERY DATES' (faster, cheaper, less traceable)
  Costs: shortfall at the end of the horizon x price of each option (REAL ECB FX + Eurostat + FranceAgriMer).
-#}
with latest as (
    select * from {{ ref('gold_supply_coverage_weekly') }}
    where as_of_date = (select max(as_of_date) from {{ ref('gold_supply_coverage_weekly') }})
),
per_variety as (
    select
        as_of_date, variety_code,
        min(case when coverage_status = 'RED' then week_number end)   as first_red_week,
        min(case when coverage_status = 'RED' then iso_week end)      as first_red_iso_week,
        max(case when coverage_status = 'AMBER' then 1 else 0 end)    as has_amber,
        min(coverage_ratio)                                           as min_coverage_ratio,
        max(shortfall_kg)                                             as max_shortfall_kg,
        max(case when week_number = {{ var('horizon_weeks') }} then coverage_ratio end) as coverage_ratio_end_of_horizon,
        max(released_kg)                                              as released_kg
    from latest
    group by 1, 2
)
select
    p.*,
    case when p.first_red_week is not null then 'RED' when p.has_amber = 1 then 'AMBER' else 'GREEN' end as overall_status,
    case
        when p.first_red_week is null and p.has_amber = 0 then 'OK - no action'
        when p.first_red_week is null                    then 'WATCH - re-check next Monday'
        when p.first_red_week >= 4                       then 'BUY FROM PARTNER STOCK'
        else                                                  'SPOT IMPORT + RENEGOTIATE DELIVERY DATES'
    end                                                                     as recommended_action,
    round(r.partner_price_eur_kg, 2)                                        as partner_price_eur_kg,
    round(r.spot_price_eur_kg, 2)                                           as spot_price_eur_kg,
    round(p.max_shortfall_kg * r.partner_price_eur_kg, 0)                   as cost_partner_option_eur,
    round(p.max_shortfall_kg * r.spot_price_eur_kg, 0)                      as cost_spot_option_eur,
    round(p.max_shortfall_kg * v.bulk_price_eur_kg_2024 * 1.45, 0)          as revenue_at_risk_eur,
    r.eurostat_latest_month
from per_variety p
join {{ ref('int_price_references') }} r using (variety_code)
join {{ ref('honey_varieties') }} v using (variety_code)
