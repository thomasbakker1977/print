#!/usr/bin/env bash
# One-time Vault setup for LifeChart. Run as a Vault admin:
#
#   export VAULT_ADDR=https://vault.example.lan:8200
#   vault login
#   GITLAB_URL=https://gitlab01.example.lan GITLAB_PROJECT=thomas/lifechart ./setup.sh
#
# Creates (idempotently):
#   - a KV v2 mount (default: secret/)
#   - a JWT auth method that trusts gitlab01's CI job tokens
#   - policies and roles for the Terraform and deploy jobs, limited to the
#     protected branches of the LifeChart project
set -euo pipefail

: "${VAULT_ADDR:?set VAULT_ADDR}"
: "${GITLAB_URL:?set GITLAB_URL, e.g. https://gitlab01.example.lan}"
: "${GITLAB_PROJECT:?set GITLAB_PROJECT, the project path, e.g. thomas/lifechart}"
KV_MOUNT="${KV_MOUNT:-secret}"
AUTH_PATH="${AUTH_PATH:-jwt-gitlab}"
GITLAB_CA_PEM="${GITLAB_CA_PEM:-}"   # path to gitlab01's CA certificate if it uses a private CA
GITLAB_URL="${GITLAB_URL%/}"

if ! vault secrets list -format=json | grep -q "\"${KV_MOUNT}/\""; then
  vault secrets enable -path="$KV_MOUNT" -version=2 kv
fi

if ! vault auth list -format=json | grep -q "\"${AUTH_PATH}/\""; then
  vault auth enable -path="$AUTH_PATH" jwt
fi

config_args=(oidc_discovery_url="$GITLAB_URL" bound_issuer="$GITLAB_URL")
if [ -n "$GITLAB_CA_PEM" ]; then
  config_args+=(oidc_discovery_ca_pem=@"$GITLAB_CA_PEM")
fi
vault write "auth/${AUTH_PATH}/config" "${config_args[@]}"

vault policy write lifechart-terraform - <<POLICY
# Read the Cloudflare API token, write what Terraform creates.
path "${KV_MOUNT}/data/lifechart/ci"            { capabilities = ["read"] }
path "${KV_MOUNT}/data/lifechart/cloudflare"    { capabilities = ["create", "update", "read"] }
path "${KV_MOUNT}/metadata/lifechart/*"         { capabilities = ["read"] }
path "sys/mounts/${KV_MOUNT}"                   { capabilities = ["read"] }
POLICY

vault policy write lifechart-deploy - <<POLICY
# Read what the homelab containers need.
path "${KV_MOUNT}/data/lifechart/app"           { capabilities = ["read"] }
path "${KV_MOUNT}/data/lifechart/cloudflare"    { capabilities = ["read"] }
POLICY

for role in terraform deploy; do
  vault write "auth/${AUTH_PATH}/role/lifechart-${role}" - <<ROLE
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["${VAULT_ADDR}"],
  "bound_claims_type": "glob",
  "bound_claims": {
    "project_path": "${GITLAB_PROJECT}",
    "ref_type": "branch",
    "ref_protected": "true"
  },
  "token_policies": ["lifechart-${role}"],
  "token_ttl": "15m",
  "token_max_ttl": "30m"
}
ROLE
done

cat <<DONE

Vault is ready. Now store your secrets (run these yourself; never commit them):

  vault kv put -mount=${KV_MOUNT} lifechart/ci \\
      cloudflare_api_token='<Cloudflare API token>'

  vault kv put -mount=${KV_MOUNT} lifechart/app \\
      lifechart_api_token="\$(openssl rand -hex 32)" \\
      anthropic_api_key='<Anthropic API key>'

  # optional, only if you do not use the interactive Garmin login:
  vault kv patch -mount=${KV_MOUNT} lifechart/app garmin_email='…' garmin_password='…'
DONE
