-- The decision horizon: the next {{ var('horizon_weeks') }} ISO weeks after the decision date (W+1 ... W+n).
{{ config(materialized='view') }}
with n as (
    {% for k in range(1, var('horizon_weeks') + 1) %}
    select {{ k }} as week_number {% if not loop.last %}union all{% endif %}
    {% endfor %}
)
select
    {{ as_of_date() }}                                                as as_of_date,
    week_number,
    {{ add_days(week_start(as_of_date()), '7 * week_number') }}       as week_start
from n
