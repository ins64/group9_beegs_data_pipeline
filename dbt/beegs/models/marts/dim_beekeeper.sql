-- Partner beekeepers with their reliability. email / phone are MASKED by a Snowflake masking policy for every role
-- except BEEGS_PURCHASING and BEEGS_ADMIN (post-hook below, policy in snowflake/05_security.sql). IBAN never reaches GOLD.
{{ config(post_hook=[
    "{% if target.type == 'snowflake' %}alter table {{ this }} modify column email set masking policy BEEGS.OPS.MASK_PII{% endif %}",
    "{% if target.type == 'snowflake' %}alter table {{ this }} modify column phone set masking policy BEEGS.OPS.MASK_PII{% endif %}"
]) }}
select
    b.beekeeper_id, b.full_name, b.email, b.phone, b.apiary_id, a.apiary_name, a.region, b.country_code, b.currency,
    b.hives_count, b.is_organic, b.partner_since,
    r.n_delivered_365d, round(r.reliability, 3) as reliability_365d
from {{ ref('stg_portal__beekeepers') }} b
left join {{ ref('int_beekeeper_reliability') }} r using (beekeeper_id)
left join {{ ref('apiaries') }} a on a.apiary_id = b.apiary_id
where b.reject_reason is null
