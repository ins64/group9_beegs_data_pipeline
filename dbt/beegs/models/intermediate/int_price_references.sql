{#-
  What it costs to fill a shortfall, per variety (EUR/kg):
    partner_price_eur_kg  average price declared by our partner beekeepers over the last 365 days, converted to EUR
                          with the REAL ECB rate of the declaration day (HUF/RON partners), x partner premium (+5 %)
    spot_price_eur_kg     REAL Eurostat unit value of EU honey imports (last 3 published months, all extra-EU origins)
                          x variety premium (FranceAgriMer bulk price of the variety / multifloral price)
                          x landed-cost factor (+12 %: transport, customs, extra lab test)
-#}
with fx as (
    -- validity interval of each ECB rate (week-ends/holidays use the last published rate)
    select rate_date, currency, eur_rate,
           coalesce(lead(rate_date) over (partition by currency order by rate_date), cast('2999-12-31' as date)) as valid_to
    from {{ ref('stg_ecb__fx_rates') }}
),
decl as (
    select d.variety_code, d.declared_kg, d.price_per_kg_local, d.currency, d.declared_at
    from {{ ref('int_declarations_asof') }} d
    where d.declared_at > {{ add_days(as_of_date(), -365) }} and d.price_per_kg_local > 0
),
decl_eur as (
    select
        d.variety_code, d.declared_kg,
        case when d.currency = 'EUR' then d.price_per_kg_local else d.price_per_kg_local / f.eur_rate end as price_eur_kg
    from decl d
    left join fx f on f.currency = d.currency and d.declared_at >= f.rate_date and d.declared_at < f.valid_to
),
partner as (
    select variety_code, sum(price_eur_kg * declared_kg) / nullif(sum(declared_kg), 0) as avg_partner_price_eur_kg
    from decl_eur where price_eur_kg is not null group by 1
),
eurostat as (
    select sum(value_eur) / nullif(sum(quantity_kg), 0) as import_unit_value_eur_kg, max(period_month) as latest_month
    from {{ ref('stg_eurostat__honey_imports') }}
    where period_month > {{ dbt.dateadd('month', -3, "(select max(period_month) from " ~ ref('stg_eurostat__honey_imports') ~ " where period_month < " ~ as_of_date() ~ ")") }}
      and period_month < {{ as_of_date() }}
),
tf as (select bulk_price_eur_kg_2024 as tf_price from {{ ref('honey_varieties') }} where variety_code = 'TOUTES_FLEURS')
select
    v.variety_code,
    v.bulk_price_eur_kg_2024,
    coalesce(p.avg_partner_price_eur_kg, v.bulk_price_eur_kg_2024) * {{ var('partner_premium_factor') }} as partner_price_eur_kg,
    e.import_unit_value_eur_kg,
    e.latest_month                                                                                      as eurostat_latest_month,
    e.import_unit_value_eur_kg * (v.bulk_price_eur_kg_2024 / tf.tf_price) * {{ var('landed_cost_factor') }} as spot_price_eur_kg
from {{ ref('honey_varieties') }} v
cross join eurostat e
cross join tf
left join partner p using (variety_code)
