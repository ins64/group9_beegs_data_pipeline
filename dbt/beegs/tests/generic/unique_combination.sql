{#- Generic test without any package (dbt Projects on Snowflake needs no external access this way):
    fails with the duplicated combinations. -#}
{% test unique_combination(model, columns) %}
select {{ columns | join(', ') }}, count(*) as n
from {{ model }}
group by {{ columns | join(', ') }}
having count(*) > 1
{% endtest %}
