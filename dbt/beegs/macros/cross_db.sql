{#-
  Cross-database helpers: the SAME models run on Snowflake (prod) and DuckDB (local dev).
  Only the few functions whose syntax differs are wrapped here; everything else is standard SQL.
-#}

{# JSON value as text. path uses dots: 'payload.daily' #}
{% macro json_str(col, path) -%}
  {%- if target.type == 'snowflake' -%} {{ col }}:{{ path }}::varchar
  {%- else -%} json_extract_string({{ col }}, '$.{{ path }}') {%- endif -%}
{%- endmacro %}

{# element idx of a JSON array (optionally a key inside that element) as text #}
{% macro json_array_at(col, path, idx, sub=none) -%}
  {%- if target.type == 'snowflake' -%} get({{ col }}:{{ path }}, {{ idx }}){% if sub %}:{{ sub }}{% endif %}::varchar
  {%- else -%} json_extract_string({{ col }}, '$.{{ path }}[' || {{ idx }} || ']{% if sub %}.{{ sub }}{% endif %}') {%- endif -%}
{%- endmacro %}

{# FROM-clause fragment exploding a JSON array; use flat_idx(alias) to get the position #}
{% macro flatten_array(col, path, alias='f') -%}
  {%- if target.type == 'snowflake' -%} lateral flatten(input => {{ col }}:{{ path }}) {{ alias }}
  {%- else -%} unnest(range(cast(coalesce(json_array_length({{ col }}, '$.{{ path }}'), 0) as bigint))) as {{ alias }}(idx) {%- endif -%}
{%- endmacro %}
{% macro flat_idx(alias='f') -%}{%- if target.type == 'snowflake' -%}{{ alias }}.index{%- else -%}{{ alias }}.idx{%- endif -%}{%- endmacro %}

{# text -> number, NULL when not a number (never fails the run) #}
{% macro try_number(expr) -%}
  {%- if target.type == 'snowflake' -%} try_to_double({{ expr }})
  {%- else -%} try_cast({{ expr }} as double) {%- endif -%}
{%- endmacro %}

{# remove every match of a regex (Snowflake replaces all matches by default, DuckDB needs the 'g' flag) #}
{% macro regexp_remove(expr, pattern) -%}
  {%- if target.type == 'snowflake' -%} regexp_replace({{ expr }}, '{{ pattern }}', '')
  {%- else -%} regexp_replace({{ expr }}, '{{ pattern }}', '', 'g') {%- endif -%}
{%- endmacro %}

{# "1 200,5 kg", "17,8 %", " 3 " -> 1200.5 / 17.8 / 3  (keeps digits, sign and decimal separator; comma = decimal) #}
{% macro clean_number(expr) -%}
  {{ try_number("replace(" ~ regexp_remove("trim(" ~ expr ~ ")", "[^0-9,.-]") ~ ", ',', '.')") }}
{%- endmacro %}

{# mixed date formats seen in the sources: 2026-09-03, 03/09/2026, 20260903, 03 Sep 2026 #}
{% macro parse_date_multi(expr) -%}
  {%- if target.type == 'snowflake' -%}
  coalesce(try_to_date(left(trim({{ expr }}), 10), 'YYYY-MM-DD'), try_to_date(trim({{ expr }}), 'DD/MM/YYYY'),
           try_to_date(trim({{ expr }}), 'YYYYMMDD'), try_to_date(trim({{ expr }}), 'DD MON YYYY'))
  {%- else -%}
  coalesce(try_strptime(left(trim({{ expr }}), 10), '%Y-%m-%d'), try_strptime(trim({{ expr }}), '%d/%m/%Y'),
           try_strptime(trim({{ expr }}), '%Y%m%d'), try_strptime(trim({{ expr }}), '%d %b %Y'))::date
  {%- endif -%}
{%- endmacro %}

{# ISO-8601 text with zone, or epoch seconds, -> timestamp with time zone (UTC) #}
{% macro parse_ts(expr) -%}
  {%- if target.type == 'snowflake' -%}
  case when regexp_count(trim({{ expr }}), '^[0-9]{9,11}$') = 1 then to_timestamp_tz(to_number(trim({{ expr }})))
       else try_to_timestamp_tz(trim({{ expr }})) end
  {%- else -%}
  case when regexp_full_match(trim({{ expr }}), '[0-9]{9,11}') then to_timestamp(cast(trim({{ expr }}) as bigint))
       else try_cast(trim({{ expr }}) as timestamptz) end
  {%- endif -%}
{%- endmacro %}

{# 'Y', 'yes', '1', 'TRUE' / 'N', 'no', '0', 'false' -> boolean, anything else NULL #}
{% macro parse_bool(expr) -%}
  case when upper(trim({{ expr }})) in ('Y', 'YES', '1', 'TRUE', 'OUI') then true
       when upper(trim({{ expr }})) in ('N', 'NO', '0', 'FALSE', 'NON') then false end
{%- endmacro %}

{# 'YYYY-Www' -> monday of that ISO week. Jan 4th is always in ISO week 1. #}
{% macro iso_week_to_monday(expr) -%}
  {%- set y = "cast(left(" ~ expr ~ ", 4) as integer)" -%}
  {%- set w = "cast(right(" ~ expr ~ ", 2) as integer)" -%}
  {%- if target.type == 'snowflake' -%}
  dateadd(day, ({{ w }} - 1) * 7, date_trunc('week', date_from_parts({{ y }}, 1, 4)))::date
  {%- else -%}
  (date_trunc('week', make_date({{ y }}, 1, 4)) + to_days((({{ w }} - 1) * 7)::integer))::date
  {%- endif -%}
{%- endmacro %}

{# date -> 'YYYY-Www' #}
{% macro iso_week(expr) -%}
  {%- if target.type == 'snowflake' -%} yearofweekiso({{ expr }})::varchar || '-W' || lpad(weekiso({{ expr }})::varchar, 2, '0')
  {%- else -%} strftime({{ expr }}, '%G-W%V') {%- endif -%}
{%- endmacro %}

{# monday of the week of a date #}
{% macro week_start(expr) -%} cast({{ dbt.date_trunc('week', expr) }} as date) {%- endmacro %}

{# add n days to a date, result is a DATE on both engines #}
{% macro add_days(expr, n) -%} cast({{ dbt.dateadd('day', n, expr) }} as date) {%- endmacro %}

{# the decision date: var as_of_date, or the latest WMS snapshot available #}
{% macro as_of_date() -%}
  {%- if var('as_of_date') -%} cast('{{ var("as_of_date") }}' as date)
  {%- else -%} (select max(snapshot_date) from {{ ref('stg_wms__stock_snapshots') }}) {%- endif -%}
{%- endmacro %}

{# incremental strategy differs per engine (DuckDB adapter: delete+insert) #}
{% macro incr_strategy() -%}{%- if target.type == 'snowflake' -%}merge{%- else -%}delete+insert{%- endif -%}{%- endmacro %}
