"""
BeeG's - Supply coverage cockpit (Streamlit in Snowflake)
=========================================================
Who: the Head of Sourcing, every Monday 08:00.   Question: "Which variety will we fail to deliver, when, and what do I do?"
Reads GOLD (+ the FinOps views of OPS). Writes one thing: the decision (DECISION_LOG), with the viewer's user name.
Note: Streamlit in Snowflake runs with the OWNER's rights. Access is granted by sharing the app with a role
(BEEGS_PURCHASING only); the allowed/denied demo of roles is done in worksheets (snowflake/05_security.sql).

Deploy: Snowsight > Projects > Streamlit > + Streamlit App > database BEEGS, schema GOLD, warehouse BEEGS_BI_WH,
paste this file. Packages: none beyond the default (streamlit, pandas, snowflake-snowpark-python).
"""
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="BeeG's - Supply coverage", layout="wide")
session = get_active_session()

BROWN, ORANGE, RED, AMBER, GREEN = "#2B0F06", "#E8820C", "#C0392B", "#E8A33D", "#4E8F3A"


@st.cache_data(ttl=600)   # 10 min cache: a dashboard refresh does not re-run the warehouse each click (cost)
def load(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()


def table(df: pd.DataFrame, index_col: str):
    """Show a table without the pandas index. hide_index= needs Streamlit >= 1.23; the default
    Streamlit in Snowflake runtime is older, so we use the first column as index instead."""
    st.dataframe(df.set_index(index_col), use_container_width=True)


actions = load("select * from BEEGS.GOLD.GOLD_COVERAGE_ACTIONS order by min_coverage_ratio")
weekly = load("""select variety_code, week_number, iso_week, coverage_ratio, coverage_status, shortfall_kg,
                        cumulative_supply_kg, cumulative_demand_kg, as_of_date
                 from BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY
                 where as_of_date = (select max(as_of_date) from BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY)""")
health = load("select source_name, last_loaded_at, bronze_rows, quarantined_rows from BEEGS.GOLD.GOLD_PIPELINE_HEALTH order by source_name")

as_of = weekly["AS_OF_DATE"].max()
st.markdown(f"<h1 style='color:{ORANGE};margin-bottom:0'>BeeG's · Supply coverage</h1>", unsafe_allow_html=True)
st.caption(f"Decision date {as_of} · next 8 weeks · source BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY · "
           f"data loaded up to {pd.to_datetime(health['LAST_LOADED_AT']).max():%Y-%m-%d %H:%M}")

# ---------- KPI row ---------------------------------------------------------------------------------------
c1, c2, c3, c4 = st.columns(4)
c1.metric("Varieties RED", int((actions["OVERALL_STATUS"] == "RED").sum()), help="Coverage < 0.90 within 8 weeks")
c2.metric("Varieties AMBER", int((actions["OVERALL_STATUS"] == "AMBER").sum()), help="0.90 <= coverage < 1.10")
c3.metric("Shortfall (kg)", f"{actions['MAX_SHORTFALL_KG'].sum():,.0f}")
c4.metric("B2B revenue at risk", f"{actions['REVENUE_AT_RISK_EUR'].sum():,.0f} €")

# ---------- Heatmap variety x week -----------------------------------------------------------------------
st.subheader("Which variety runs short, and when?")
pivot = weekly.pivot(index="VARIETY_CODE", columns="ISO_WEEK", values="COVERAGE_RATIO").reindex(actions["VARIETY_CODE"])


def color(v):
    if pd.isna(v):
        return ""
    c = RED if v < 0.9 else AMBER if v < 1.1 else GREEN
    return f"background-color:{c};color:white;font-weight:600"


st.dataframe(pivot.style.format("{:.2f}").map(color), use_container_width=True)
st.caption("Coverage ratio = (released stock + pending lab x pass rate + expected arrivals) / (B2B demand + B2C reserve), cumulated week by week.")

# ---------- Actions ---------------------------------------------------------------------------------------
st.subheader("What should I do this week?")
show = actions[["VARIETY_CODE", "OVERALL_STATUS", "FIRST_RED_ISO_WEEK", "MAX_SHORTFALL_KG", "RECOMMENDED_ACTION",
                "PARTNER_PRICE_EUR_KG", "COST_PARTNER_OPTION_EUR", "SPOT_PRICE_EUR_KG", "COST_SPOT_OPTION_EUR"]]
table(show, "VARIETY_CODE")

sel = st.selectbox("Variety detail", actions["VARIETY_CODE"])
d = weekly[weekly["VARIETY_CODE"] == sel].sort_values("WEEK_NUMBER")
chart = d.set_index("ISO_WEEK")[["CUMULATIVE_SUPPLY_KG", "CUMULATIVE_DEMAND_KG"]]
try:
    st.line_chart(chart, color=[GREEN, ORANGE])   # color= needs Streamlit >= 1.27
except TypeError:
    st.line_chart(chart)

# ---------- Decision write-back (SQL INSERT) --------------------------------------------------------------
with st.form("decision"):
    st.markdown("**Record my decision** (kept in BEEGS.GOLD.DECISION_LOG to measure later what worked)")
    act = st.selectbox("Action", ["BUY FROM PARTNER STOCK", "SPOT IMPORT", "RENEGOTIATE DELIVERY DATES", "NO ACTION"])
    kg = st.number_input("Quantity (kg)", min_value=0.0, step=100.0,
                         value=float(actions.loc[actions["VARIETY_CODE"] == sel, "MAX_SHORTFALL_KG"].iloc[0]))
    comment = st.text_input("Comment")
    if st.form_submit_button("Save decision"):
        try:
            viewer = (getattr(st, "experimental_user", {}) or {}).get("user_name", "unknown")
            session.sql("insert into BEEGS.GOLD.DECISION_LOG (decided_by, as_of_date, variety_code, action, quantity_kg, comment) values (?, ?, ?, ?, ?, ?)",
                        params=[viewer, str(as_of), sel, act, kg, comment]).collect()
            st.success(f"Decision saved by {viewer}.")
        except Exception as e:
            st.error(f"Could not save the decision: {e}")

# ---------- Pipeline health -------------------------------------------------------------------------------
with st.expander("Pipeline health (freshness & quarantine per source)"):
    table(health, "SOURCE_NAME")

# ---------- FinOps: what does this tool cost? -------------------------------------------------------------
with st.expander("Costs (FinOps): what does this tool cost?"):
    try:
        cost = load("""select usage_date, split_part(service, ':', 1) as service_type, sum(cost_eur) as cost_eur
                       from BEEGS.OPS.FINOPS_DAILY_COST where usage_date >= dateadd(day, -30, current_date())
                       group by 1, 2 order by 1""")
        unit = load("select * from BEEGS.OPS.FINOPS_UNIT_ECONOMICS limit 1")
        if not unit.empty:
            u1, u2, u3 = st.columns(3)
            u1.metric("Snowflake this month", f"{unit['SNOWFLAKE_EUR'].iloc[0]:,.2f} €")
            u2.metric("Cost per weekly decision", f"{unit['EUR_PER_WEEKLY_DECISION'].iloc[0]:,.2f} €")
            u3.metric("Credits this month", f"{unit['CREDITS'].iloc[0]:,.2f}")
        st.bar_chart(cost.pivot_table(index="USAGE_DATE", columns="SERVICE_TYPE", values="COST_EUR", aggfunc="sum").fillna(0))
        st.caption("Source BEEGS.OPS.FINOPS_DAILY_COST (ACCOUNT_USAGE, up to 3 h latency). GitHub Actions minutes: repository Settings > Billing (docs/09).")
    except Exception as e:
        st.info(f"FinOps views not available yet: {e}")
