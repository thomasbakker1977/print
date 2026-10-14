#!/usr/bin/env bash
# Creates the private LifeChart project on gitlab01 and pushes the code.
# Run once from your Mac (which can reach gitlab01), inside the cloned `print` repo:
#
#   LifeChart/infra/bootstrap-gitlab.sh
#
# It asks for anything not set as an environment variable: GITLAB_URL,
# GITLAB_TOKEN (personal access token with the "api" scope) and VAULT_ADDR.
# Cloudflare settings live in Vault (lifechart/ci), not in GitLab.
# ~/ipa-ca.pem is used as CA bundle for gitlab01 and Vault when it exists.
#
# Optional: GITLAB_NAMESPACE (group path; default your user), PROJECT_NAME
# (default lifechart), GITLAB_CA_PEM (CA certificate of gitlab01 if it uses an
# internal CA), VAULT_CA_PEM (CA certificate of your Vault server).
set -euo pipefail

# Ask for anything not given as an environment variable.
ask() {
  local name="$1" prompt="$2" default="${3:-}" secret="${4:-}" value
  if [ -n "${!name:-}" ]; then return; fi
  if [ -n "$default" ]; then prompt="$prompt [$default]"; fi
  if [ -n "$secret" ]; then
    read -r -s -p "$prompt: " value; echo
  else
    read -r -p "$prompt: " value
  fi
  value="${value:-$default}"
  if [ -z "$value" ]; then echo "$name is required." >&2; exit 1; fi
  printf -v "$name" '%s' "$value"
}

default_ca=""
if [ -f "$HOME/ipa-ca.pem" ]; then default_ca="$HOME/ipa-ca.pem"; fi

ask GITLAB_URL "GitLab URL" "https://gitlab01.corp.datafor.business"
ask GITLAB_TOKEN "GitLab personal access token (api scope, input hidden)" "" secret
ask VAULT_ADDR "Vault address" "https://vault.corp.datafor.business:8200"
if [ -n "$default_ca" ]; then
  GITLAB_CA_PEM="${GITLAB_CA_PEM:-$default_ca}"
  VAULT_CA_PEM="${VAULT_CA_PEM:-$default_ca}"
fi
GITLAB_URL="${GITLAB_URL%/}"
PROJECT_NAME="${PROJECT_NAME:-lifechart}"

for name in GITLAB_TOKEN VAULT_ADDR; do
  case "${!name}" in
    *"<"*|*">"*) echo "Replace the placeholder in $name with your real value." >&2; exit 1 ;;
  esac
done
API="$GITLAB_URL/api/v4"

curl_tls=()
git_tls=()
if [ -n "${GITLAB_CA_PEM:-}" ]; then
  curl_tls=(--cacert "$GITLAB_CA_PEM")
  git_tls=(-c "http.sslCAInfo=$GITLAB_CA_PEM")
fi

# Calls the GitLab API; on an error, prints GitLab's explanation and fails.
# Set QUIET_404=1 for lookups where "not found" is an expected answer.
api() {
  local method="$1" path="$2" body status
  shift 2
  body="$(curl -sS ${curl_tls[@]+"${curl_tls[@]}"} -X "$method" -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -w '\n%{http_code}' "$API$path" "$@")" || return 1
  status="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [ "$status" -ge 400 ]; then
    if [ "$status" != 404 ] || [ -z "${QUIET_404:-}" ]; then
      echo "GitLab API $method $path failed ($status): $body" >&2
    fi
    return 1
  fi
  printf '%s\n' "$body"
}
json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
urlencode() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }

# 1. Project (private)
namespace_args=()
if [ -n "${GITLAB_NAMESPACE:-}" ]; then
  namespace_id="$(api GET "/namespaces/$(urlencode "$GITLAB_NAMESPACE")" | json "['id']")"
  namespace_args=(--data-urlencode "namespace_id=$namespace_id")
fi
if ! user_json="$(api GET /user)"; then
  echo "GitLab rejected the token (check GITLAB_TOKEN: a personal access token with the api scope)." >&2
  exit 1
fi
owner="${GITLAB_NAMESPACE:-$(echo "$user_json" | json "['username']")}"
project_path="$owner/$PROJECT_NAME"
if project_json="$(QUIET_404=1 api GET "/projects/$(urlencode "$project_path")")"; then
  echo "Project $project_path already exists."
else
  project_json="$(api POST /projects --data-urlencode "name=$PROJECT_NAME" \
    --data-urlencode "visibility=private" --data-urlencode "initialize_with_readme=false" \
    ${namespace_args[@]+"${namespace_args[@]}"})"
  echo "Created private project $project_path."
fi
project_id="$(echo "$project_json" | json "['id']")"
http_url="$(echo "$project_json" | json "['http_url_to_repo']")"

# 2. CI/CD variables (none of these are secrets; secrets and Cloudflare
#    settings live in Vault)
set_variable() {
  local key="$1" value="$2" type="${3:-env_var}"
  QUIET_404=1 api PUT "/projects/$project_id/variables/$key" --data-urlencode "value=$value" \
      --data-urlencode "variable_type=$type" >/dev/null \
    || api POST "/projects/$project_id/variables" --data-urlencode "key=$key" \
      --data-urlencode "value=$value" --data-urlencode "variable_type=$type" >/dev/null
  echo "  variable $key set"
}
set_variable VAULT_ADDR "$VAULT_ADDR"
if [ -n "${VAULT_CA_PEM:-}" ]; then
  set_variable VAULT_CACERT "$(cat "$VAULT_CA_PEM")" file
fi

# 3. Runner for the homelab (shell executor)
runner_json="$(api POST /user/runners --data-urlencode "runner_type=project_type" \
  --data-urlencode "project_id=$project_id" --data-urlencode "tag_list=homelab" \
  --data-urlencode "run_untagged=false" --data-urlencode "description=homelab")"
runner_token="$(echo "$runner_json" | json "['token']")"

# 4. Push the LifeChart folder as the project's main branch
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
git subtree split --prefix=LifeChart -b lifechart-gitlab >/dev/null
# Push over HTTPS with the access token in a header (no SSH key needed, and the
# token never ends up in a URL or the git config).
auth="$(printf 'oauth2:%s' "$GITLAB_TOKEN" | base64 | tr -d '\n')"
git ${git_tls[@]+"${git_tls[@]}"} -c credential.helper= -c "http.extraHeader=Authorization: Basic $auth" \
  push "$http_url" lifechart-gitlab:main
git branch -D lifechart-gitlab >/dev/null

cat <<DONE

Done. Project: $project_path

Next:

  0. Configure Vault for this project (see infra/README.md, step 3):
       GITLAB_URL=$GITLAB_URL GITLAB_PROJECT=$project_path LifeChart/infra/vault/setup.sh

  On the homelab (as root):

  1. Register the runner (shell executor):
       gitlab-runner register --non-interactive --url "$GITLAB_URL" \\
         --token "$runner_token" --executor shell --description homelab
     and give it Docker access:  usermod -aG docker gitlab-runner
     (the runner also needs rsync).

  2. Prepare the deploy folder:
       install -d -o gitlab-runner -m 700 /opt/lifechart
       install -d -o 1000 -g 1000 -m 700 /opt/lifechart/data

  3. In GitLab, open $GITLAB_URL/$project_path/-/pipelines,
     run the pipeline on main and click ▶ on terraform:apply.

Keep the runner token above private; it is shown only once.
DONE
