#!/usr/bin/env bash
# Deploys the LifeChart backend on the homelab. Runs in the GitLab "deploy" job
# on the homelab runner (shell executor, user in the docker group).
#
# Secrets are fetched from Vault with the job's GitLab JWT and written to an
# .env file readable only by the runner user.
set -euo pipefail

: "${VAULT_ADDR:?}"
: "${VAULT_ID_TOKEN:?}"
KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
AUTH_PATH="${VAULT_AUTH_PATH:-jwt-gitlab}"
VAULT_IMAGE="hashicorp/vault:${VAULT_VERSION:-1.17.6}"
DEPLOY_DIR="${LIFECHART_DIR:-/opt/lifechart}"
SOURCE_DIR="$(cd "$(dirname "$0")/../../backend" && pwd)"

# Run the Vault CLI from its container so the homelab needs nothing but Docker.
vault() {
  local args=(--rm -e VAULT_ADDR -e VAULT_TOKEN)
  if [ -n "${VAULT_CACERT:-}" ]; then
    args+=(-e VAULT_CACERT=/ca.pem -v "${VAULT_CACERT}:/ca.pem:ro")
  fi
  docker run "${args[@]}" "$VAULT_IMAGE" vault "$@"
}

VAULT_TOKEN="$(vault write -field=token "auth/${AUTH_PATH}/login" role=lifechart-deploy jwt="$VAULT_ID_TOKEN")"
export VAULT_TOKEN

field() { vault kv get -mount="$KV_MOUNT" -field="$2" "lifechart/$1"; }
optional_field() { field "$1" "$2" 2>/dev/null || true; }

umask 077
mkdir -p "$DEPLOY_DIR"
rsync -a --delete --exclude data/ --exclude .env "$SOURCE_DIR/" "$DEPLOY_DIR/"
if [ ! -d "$DEPLOY_DIR/data" ]; then
  echo "Create the data folder once with: sudo install -d -o 1000 -g 1000 -m 700 $DEPLOY_DIR/data" >&2
  exit 1
fi

{
  echo "LIFECHART_API_TOKEN=$(field app lifechart_api_token)"
  echo "ANTHROPIC_API_KEY=$(field app anthropic_api_key)"
  echo "CLOUDFLARE_TUNNEL_TOKEN=$(field cloudflare tunnel_token)"
  echo "CF_ACCESS_TEAM_DOMAIN=$(field cloudflare access_team_domain)"
  echo "CF_ACCESS_AUD=$(field cloudflare access_aud)"
  echo "COACH_CRISIS_INFO=113 Zelfmoordpreventie (bel 113 of 0800-0113, of chat via 113.nl), de huisartsenpost, of 112 bij direct gevaar"
  echo "TZ=${TZ:-Europe/Amsterdam}"
  garmin_email="$(optional_field app garmin_email)"
  garmin_password="$(optional_field app garmin_password)"
  if [ -n "$garmin_email" ]; then echo "GARMIN_EMAIL=$garmin_email"; fi
  if [ -n "$garmin_password" ]; then echo "GARMIN_PASSWORD=$garmin_password"; fi
} > "$DEPLOY_DIR/.env.new"
mv "$DEPLOY_DIR/.env.new" "$DEPLOY_DIR/.env"
unset VAULT_TOKEN

cd "$DEPLOY_DIR"
docker compose up -d --build --remove-orphans

echo "Waiting for LifeChart to become healthy…"
for _ in $(seq 1 30); do
  status="$(docker inspect --format '{{.State.Health.Status}}' lifechart 2>/dev/null || echo starting)"
  if [ "$status" = "healthy" ]; then
    echo "LifeChart is healthy."
    exit 0
  fi
  sleep 5
done
docker compose logs --tail 50 lifechart
echo "LifeChart did not become healthy in time." >&2
exit 1
