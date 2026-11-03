-- The 8 honey varieties with their seasons and current price references (partner vs spot).
select v.*, r.partner_price_eur_kg, r.spot_price_eur_kg, r.import_unit_value_eur_kg, r.eurostat_latest_month
from {{ ref('honey_varieties') }} v
left join {{ ref('int_price_references') }} r using (variety_code, bulk_price_eur_kg_2024)
