-- =====================================================================================================
-- 04_quality_and_alerts.sql  (deployed by CI AFTER the first dbt build: the alert reads GOLD)  -  monitoring that runs OUTSIDE the daily dbt build
--   * Data Metric Functions on the streaming table (hive events arrive all day, dbt runs once a day)
--   * A_HIVE_FEED_STALE  : data alert  -> data team   (streaming source silent for 6 h)
--   * A_COVERAGE_RED     : business alert -> Head of Sourcing (a variety turned RED today)
-- =====================================================================================================
USE ROLE BEEGS_PIPELINE;
USE WAREHOUSE BEEGS_PIPELINE_WH;
USE SCHEMA BEEGS.OPS;

-- ---------- Data Metric Functions (Snowflake-native, Enterprise edition) ------------------------------------
-- Measured every time new rows land (Snowpipe), results in SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS.
-- (re-runnable: adding a DMF that is already attached raises an error, which is ignored)
ALTER TABLE BEEGS.BRONZE.HIVE_EVENTS_RAW SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE BEEGS.BRONZE.LAB_RESULTS_RAW SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
EXECUTE IMMEDIATE $$
BEGIN
  BEGIN ALTER TABLE BEEGS.BRONZE.HIVE_EVENTS_RAW ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (_loaded_at); EXCEPTION WHEN OTHER THEN NULL; END;
  BEGIN ALTER TABLE BEEGS.BRONZE.HIVE_EVENTS_RAW ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();         EXCEPTION WHEN OTHER THEN NULL; END;
  BEGIN ALTER TABLE BEEGS.BRONZE.LAB_RESULTS_RAW ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (lot_id);  EXCEPTION WHEN OTHER THEN NULL; END;
  BEGIN ALTER TABLE BEEGS.BRONZE.LAB_RESULTS_RAW ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (sample_id); EXCEPTION WHEN OTHER THEN NULL; END;
  RETURN 'DMFs attached';
END;
$$;

-- ---------- Data alert: the streaming feed is silent ----------------------------------------------------------
-- Hive scales publish every 4 h -> nothing for 6 h = gateway down, extract workflow failing or pipe paused.
-- SERVERLESS alert (no WAREHOUSE clause): checking every 2 h with a warehouse would cost ~2 min of XS each time
-- (60 s minimum billing + 60 s auto-suspend) = ~12 credits/month; serverless bills only the seconds used.
CREATE OR REPLACE ALERT A_HIVE_FEED_STALE
  SCHEDULE = 'USING CRON 0 */2 * * * Europe/Paris'
  IF (EXISTS (
        SELECT 1 FROM BEEGS.BRONZE.HIVE_EVENTS_RAW
        HAVING MAX(_loaded_at) < DATEADD(hour, -6, CURRENT_TIMESTAMP())))
  THEN
    CALL SYSTEM$SEND_EMAIL('BEEGS_EMAIL', '<<DATA_TEAM_EMAIL>>',
         '[BeeGs] Hive scale feed stale',
         'No hive event loaded for 6 hours. Check: GitHub Actions workflow hive-readings, '
         || 'SELECT SYSTEM$PIPE_STATUS(''BEEGS.OPS.PIPE_HIVE_EVENTS''). Runbook INC-003.');

-- ---------- Business alert: coverage turned RED -------------------------------------------------------------
-- Runs at 07:30, after the pipeline. Only NEW reds (not red yesterday) -> no daily spam for the same variety.
CREATE OR REPLACE ALERT A_COVERAGE_RED
  SCHEDULE = 'USING CRON 30 7 * * * Europe/Paris'
  IF (EXISTS (
        SELECT 1 FROM BEEGS.GOLD.GOLD_COVERAGE_ACTIONS t
        WHERE t.overall_status = 'RED'
          AND t.as_of_date >= DATEADD(day, -1, CURRENT_DATE())
          AND NOT EXISTS (SELECT 1 FROM BEEGS.GOLD.GOLD_SUPPLY_COVERAGE_WEEKLY y
                          WHERE y.variety_code = t.variety_code AND y.as_of_date = DATEADD(day, -1, t.as_of_date)
                            AND y.coverage_status = 'RED')))
  THEN
    EXECUTE IMMEDIATE $$
    BEGIN
      LET msg VARCHAR := (SELECT LISTAGG(variety_code || ': RED from week ' || first_red_iso_week || ', shortfall '
                                  || TO_VARCHAR(max_shortfall_kg, '999,999') || ' kg -> ' || recommended_action, ' | ')
                          FROM BEEGS.GOLD.GOLD_COVERAGE_ACTIONS WHERE overall_status = 'RED');
      CALL SYSTEM$SEND_EMAIL('BEEGS_EMAIL', '<<HEAD_OF_SOURCING_EMAIL>>', '[BeeGs] Supply coverage RED', :msg);
    END;
    $$;

ALTER ALERT A_HIVE_FEED_STALE RESUME;
ALTER ALERT A_COVERAGE_RED    RESUME;

-- History of alert evaluations / actions:
-- SELECT * FROM TABLE(INFORMATION_SCHEMA.ALERT_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(day, -7, CURRENT_TIMESTAMP())));
-- DMF results:
-- SELECT * FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS WHERE table_name = 'HIVE_EVENTS_RAW' ORDER BY measurement_time DESC;
