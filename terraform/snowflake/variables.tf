variable "state_passphrase" {
  description = "Passphrase of the state encryption (GitHub secret TF_STATE_PASSPHRASE, >= 16 chars)."
  type        = string
  # not marked "sensitive": OpenTofu evaluates it in the static encryption block, where sensitive values are refused.
  # It never appears in plans or state (encryption key material only).
}

variable "private_key_path" {
  description = "Path of the BEEGS_DEPLOY_SVC private key file, written by the CI from a GitHub secret."
  type        = string
  default     = "/tmp/snowflake_deploy.p8"
}

variable "organization_name" {
  type    = string
  default = "ZEFQCKT"
}

variable "account_name" {
  type    = string
  default = "WL69349"
}
