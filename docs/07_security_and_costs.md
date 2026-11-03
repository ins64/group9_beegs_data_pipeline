# 07 · Security and costs

> See also **docs/09_finops_tco_governance.md** (FinOps monitoring, 3-year TCO vs Fivetran / dbt Cloud / Composer, governance).
>
> Criterion C7: proportionate access with allowed/denied verification; protected secrets and sensitive data; prototype cost and projection with assumptions; documented budget alert and shutdown procedure.

## 1. Access model (least privilege)

| Role | BRONZE | SILVER | GOLD | Beekeeper e-mail/phone | Write decision | Warehouse |
|---|---|---|---|---|---|---|
| `BEEGS_ADMIN` (data engineers) | ✅ owner | ✅ | ✅ | clear | ✅ | both |
| `BEEGS_PIPELINE` (tasks, dbt) | ✅ write | ✅ write | ✅ write | clear (needed to build silver) | – | PIPELINE_WH |
| `BEEGS_PURCHASING` (Head of Sourcing) | ❌ | ❌ | ✅ read | **clear** (she calls them) | ✅ INSERT | BI_WH |
| `BEEGS_ANALYST` | ❌ | ❌ | ✅ read | **\*\*\*MASKED\*\*\*** | ❌ | BI_WH |

Machine identities, each able to do one thing only:

| Identity | Can | Cannot |
|---|---|---|
| `BEEGS_PIPELINE_SVC` (extract container) | role BEEGS_PIPELINE only: PUT to the landing stage, trigger the pipes | log in to the UI (`TYPE = SERVICE`), use a password, read GOLD as an admin |
| `BEEGS_DEPLOY_SVC` (CI/CD) | role BEEGS_ADMIN: OpenTofu, SQL scripts, dbt deploy | ACCOUNTADMIN actions (users, monitors, integrations stay manual), MANAGE GRANTS |
| GitHub `GITHUB_TOKEN` | push/pull the image in GHCR for this repository | anything outside the repository |

**Allowed/denied verification** (`snowflake/05_security.sql`, screenshots in `docs/evidence/`):
- `ANALYST`: `SELECT … FROM GOLD.DIM_BEEKEEPER` returns `***MASKED***` ✅. `SELECT … FROM BRONZE.BEEKEEPERS_RAW` is ❌ *does not exist or not authorized*. `INSERT INTO GOLD.DECISION_LOG` is ❌ *insufficient privileges*.
- `PURCHASING`: same `SELECT` returns the e-mails in clear ✅, and `INSERT` works ✅.
- The Streamlit app runs with its owner's rights, so access to it is controlled by sharing it with `BEEGS_PURCHASING` only. Each saved decision records the viewer's user name. The role-by-role allowed/denied test is done in worksheets.

## 2. Secrets and sensitive data

| Item | How it is protected |
|---|---|
| Service users | **Key-pair only**, `TYPE = SERVICE` (no password can exist, no UI login). Private keys only in GitHub encrypted secrets; loaded in memory, or written to a 600-mode file on an ephemeral runner. Rotation: `ALTER USER … SET RSA_PUBLIC_KEY_2 = …` then remove the old key, with no downtime. |
| dbt → Snowflake | dbt Projects on Snowflake run as the task owner role: **no password in `profiles.yml`**. |
| Local `.env`, `terraform.tfvars`, `*.tfstate`, keys | `.gitignore` + `.dockerignore`; the image contains no secret. |
| OpenTofu state | **encrypted client-side (AES-GCM, enforced)** with a passphrase in GitHub secrets, stored in the internal stage `@BEEGS_INFRA.TFSTATE.STATE` (BEEGS_ADMIN only, Snowflake server-side encryption too). The CI concurrency group acts as the lock. Never committed. |
| **Personal data** (beekeepers' e-mail, phone, IBAN: GDPR) | masking policies on BRONZE (`MASK_PII_RAW`) and GOLD (`MASK_PII`). The **IBAN never leaves bronze** (data minimisation). Stages are internal (never public) and server-side encrypted. |
| Contract prices | GOLD only, roles PURCHASING / ANALYST (internal). |

## 3. Cost of the prototype (measured + estimated)

Prices: Snowflake Enterprise on GCP Europe (europe-west2) ≈ **$3.90/credit** (on-demand, assumption). XS warehouse = 1 credit/h, billed per second with a 60 s minimum.

| Item | Assumption | Credits/month | €/month |
|---|---|---|---|
| Daily task graph (COPY + dbt build) | ~5 min of XS/day (measured on the first runs: `06_costs_and_teardown.sql §1`) | 2.5 | ~9 |
| Streamlit + analysts | 4 sessions/week × 15 min | 1.0 | ~3.6 |
| Snowpipe (lab + hive files) | ~9,000 files/month, a few MB | ~0.3 | ~1 |
| Serverless alerts + DMFs | 2 alerts, 4 DMFs | ~0.2 | ~0.7 |
| Snowflake storage | ~1 GB compressed + 7 days Time Travel on bronze | – | ~0.05 |
| **Snowflake total** | | **~4 credits** | **~€14** |
| GitHub Actions (extraction + CI/CD) | ~1.5 min × (30 daily + 180 hive runs) + CI ≈ 6 h/month; private repo = 2,000 free min/month | | €0 |
| GHCR (container images) | < 0.5 GB, free quota | | €0 |
| **Outside Snowflake total** | | | **€0**|
| **Prototype total** | | | **≈ €15/month**, i.e. €0 during the trial (free credits) |

**Projection to production** (assumptions: 10 × the volume = 600 beekeepers, 240 hive scales, 3 decision users, 20 analysts, hourly refresh during harvest season):

| Item | Credits/month | €/month |
|---|---|---|
| Pipeline (hourly Apr-Sep, daily otherwise; ~15 min XS/run in season) | ~20 | ~€78 |
| BI (20 users, BI_WH S in office hours, with auto-suspend) | ~25 | ~€98 |
| Snowpipe, alerts, DMFs | ~3 | ~€12 |
| GitHub Actions beyond the free quota (hourly in season) / GitHub Team | | ~€15 |
| **Total** | | **≈ €200/month**, vs ~€150 k of B2B revenue protected in a poor-harvest year |

The biggest cost lever is warehouse idle time, so we use `AUTO_SUSPEND = 60`, serverless alerts instead of warehouse alerts (would have cost ~12 credits/month on their own) and a 10-minute cache in Streamlit. What would change the architecture: Cloud Composer (+€300/month) only if we orchestrate many non-Snowflake systems.

## 4. Budget alerts (documented)

- **Snowflake:** resource monitor `BEEGS_MONTHLY_RM`, 15 credits/month on both warehouses. **Notify at 75 %, suspend at 100 %, suspend immediately at 110 %** (`00_account_setup.sql`). `STATEMENT_TIMEOUT_IN_SECONDS` caps a runaway query.
- **Snowflake Budget** (`08_finops.sql`): 10 credits/month on the BEEGS database and warehouses, **including serverless** (Snowpipe, alerts, DMFs). E-mail when the *forecast* exceeds the limit.
- **GitHub:** Settings → Billing → spending limit **$0** on Actions (default for a personal account), so the minutes can never be billed.
- **Stage:** extracted files older than 180 days can be removed (`REMOVE @LANDING PATTERN=…`), since they are already loaded in bronze.

## 5. Shutdown / cleanup

See `docs/05_runbook.md §5` and `snowflake/06_costs_and_teardown.sql §2`. In order: pause the schedules → export → `terraform destroy` → drop the Snowflake objects → delete the state bucket → check the bills one week later.
