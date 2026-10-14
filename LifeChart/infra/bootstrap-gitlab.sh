#!/usr/bin/env bash
# Creates the private LifeChart project on gitlab01 and pushes the code.
# Run once from your Mac (which can reach gitlab01), inside the cloned `print` repo:
#
#   GITLAB_URL=https://gitlab01.example.lan \
#   GITLAB_TOKEN=<personal access token with "api" scope> \
#   VAULT_ADDR=https://vault.example.lan:8200 \
#   CF_ACCOUNT_ID=<Cloudflare account id> \
#   ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com \
#   LifeChart/infra/bootstrap-gitlab.sh
#
# Optional: GITLAB_NAMESPACE (group path; default your user), PROJECT_NAME
# (default lifechart), VAULT_CA_PEM (path to your Vault CA certificate).
set -euo pipefail

: "${GITLAB_URL:?}" "${GITLAB_TOKEN:?}" "${VAULT_ADDR:?}" "${CF_ACCOUNT_ID:?}" "${ACCESS_TEAM_DOMAIN:?}"
GITLAB_URL="${GITLAB_URL%/}"
PROJECT_NAME="${PROJECT_NAME:-lifechart}"
API="$GITLAB_URL/api/v4"

api() {
  local method="$1" path="$2"
  shift 2
  curl --fail-with-body -sS -X "$method" -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$API$path" "$@"
}
json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
urlencode() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }

# 1. Project (private)
namespace_args=()
if [ -n "${GITLAB_NAMESPACE:-}" ]; then
  namespace_id="$(api GET "/namespaces/$(urlencode "$GITLAB_NAMESPACE")" | json "['id']")"
  namespace_args=(--data-urlencode "namespace_id=$namespace_id")
fi
owner="${GITLAB_NAMESPACE:-$(api GET /user | json "['username']")}"
project_path="$owner/$PROJECT_NAME"
if project_json="$(api GET "/projects/$(urlencode "$project_path")" 2>/dev/null)"; then
  echo "Project $project_path already exists."
else
  project_json="$(api POST /projects --data-urlencode "name=$PROJECT_NAME" \
    --data-urlencode "visibility=private" --data-urlencode "initialize_with_readme=false" \
    "${namespace_args[@]}")"
  echo "Created private project $project_path."
fi
project_id="$(echo "$project_json" | json "['id']")"
ssh_url="$(echo "$project_json" | json "['ssh_url_to_repo']")"

# 2. CI/CD variables (none of these are secrets; secrets live in Vault)
set_variable() {
  local key="$1" value="$2" type="${3:-env_var}"
  api PUT "/projects/$project_id/variables/$key" --data-urlencode "value=$value" \
      --data-urlencode "variable_type=$type" >/dev/null 2>&1 \
    || api POST "/projects/$project_id/variables" --data-urlencode "key=$key" \
      --data-urlencode "value=$value" --data-urlencode "variable_type=$type" >/dev/null
  echo "  variable $key set"
}
set_variable VAULT_ADDR "$VAULT_ADDR"
set_variable TF_VAR_cloudflare_account_id "$CF_ACCOUNT_ID"
set_variable TF_VAR_access_team_domain "$ACCESS_TEAM_DOMAIN"
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
git push "$ssh_url" lifechart-gitlab:main
git branch -D lifechart-gitlab >/dev/null

cat <<DONE

Done. Next steps on the homelab (as root):

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
