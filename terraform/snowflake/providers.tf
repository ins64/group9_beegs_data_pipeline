# Key-pair authentication of the service user BEEGS_DEPLOY_SVC (TYPE = SERVICE: no password exists).
provider "snowflake" {
  organization_name = var.organization_name
  account_name      = var.account_name
  user              = "BEEGS_DEPLOY_SVC"
  role              = "BEEGS_ADMIN"
  authenticator     = "SNOWFLAKE_JWT"
  private_key       = file(var.private_key_path)
}
