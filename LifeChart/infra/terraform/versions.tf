terraform {
  required_version = ">= 1.6"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.52"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.4"
    }
  }

  # State lives in GitLab (gitlab01). The pipeline configures it through the
  # TF_HTTP_* environment variables; see ../../.gitlab-ci.yml.
  backend "http" {}
}

# Reads VAULT_ADDR and VAULT_TOKEN from the environment (the pipeline logs in
# with its GitLab JWT; locally use `vault login`).
provider "vault" {
  # Use the pipeline's short-lived token directly instead of minting a child token.
  skip_child_token = true
}

# The Cloudflare API token never leaves Vault except into this provider.
provider "cloudflare" {
  api_token = data.vault_kv_secret_v2.ci.data["cloudflare_api_token"]
}
