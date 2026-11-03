# Run with OpenTofu (open-source Terraform fork, Linux Foundation) because of its native STATE ENCRYPTION.
# Provider pinned (~> = minor updates only), lock file committed.
terraform {
  required_version = ">= 1.8"
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 2.1"
    }
  }

  # PROTECTED STATE. The state maps this code to real objects and must never be committed.
  # * encrypted client-side with AES-GCM (key derived from a passphrase kept in a GitHub secret), enforced:
  #   a plain-text state is refused;
  # * stored in the internal stage @BEEGS_INFRA.TFSTATE.STATE (only BEEGS_ADMIN, server-side encrypted too),
  #   downloaded before and uploaded after each run by the CI workflow;
  # * locked: the workflow runs in a GitHub "concurrency" group, so two applies can never overlap.
  encryption {
    key_provider "pbkdf2" "passphrase" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "default" {
      keys = key_provider.pbkdf2.passphrase
    }
    state {
      method   = method.aes_gcm.default
      enforced = true
    }
    plan {
      method   = method.aes_gcm.default
      enforced = true
    }
  }
}
