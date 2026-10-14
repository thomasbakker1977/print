# LifeChart infrastructure (IaC)

Everything between the iPhone and the homelab is code, run by a pipeline on
**gitlab01**, with all secrets in **Vault**.

```
iPhone ──HTTPS──▶ Cloudflare Access ──Tunnel──▶ cloudflared ──▶ lifechart (Docker, homelab)
                         ▲                                            ▲
                    Terraform (gitlab01 CI) ──writes──▶ Vault ◀──reads── deploy job (homelab runner)
```

| Path | What it does |
|---|---|
| `terraform/` | Cloudflare Tunnel, DNS record `lifechart.datafor.business`, Access application + policies, iPhone service token. Reads the Cloudflare API token from Vault and writes everything it creates back to Vault. State is stored in GitLab. |
| `vault/setup.sh` | One-time Vault setup: KV v2 mount, JWT login for gitlab01 CI, least-privilege policies and roles bound to protected branches of the project. |
| `deploy/deploy.sh` | Runs on the homelab runner: fetches secrets from Vault, writes `/opt/lifechart/.env` (mode 600), runs `docker compose up -d --build`, waits until healthy. |
| `bootstrap-gitlab.sh` | One-time: creates the private project on gitlab01, sets the (non-secret) CI variables, creates the homelab runner and pushes the code. |
| `../.gitlab-ci.yml` | validate → plan → apply (manual) → deploy. |

## Secrets in Vault (KV v2, mount `secret`)

| Path | Written by | Keys |
|---|---|---|
| `secret/lifechart/ci` | you | `cloudflare_api_token` |
| `secret/lifechart/app` | you | `lifechart_api_token`, `anthropic_api_key`, optional `garmin_email`, `garmin_password` |
| `secret/lifechart/cloudflare` | Terraform | `server_url`, `tunnel_token`, `access_aud`, `access_team_domain`, `iphone_client_id`, `iphone_client_secret` |

GitLab stores no secrets: CI jobs log in to Vault with a short-lived GitLab
JWT (`id_tokens`), and Vault only accepts tokens from protected branches of
this project. Note that the Terraform state (in GitLab) does contain the
generated Cloudflare secrets, as all Terraform state does; only maintainers
can read it.

## Setting it up

### 1. Cloudflare API token
Cloudflare dashboard → My Profile → API Tokens → Create → Custom token:

- Account · Cloudflare Tunnel · Edit
- Account · Access: Apps and Policies · Edit
- Account · Access: Service Tokens · Edit
- Zone · DNS · Edit, and Zone · Zone · Read, for zone `datafor.business`

Also note your **account ID** and Zero Trust **team domain**
(`<team>.cloudflareaccess.com`).

### 2. GitLab project (once, from your Mac)
Create a personal access token on gitlab01 with the `api` scope, then in the
cloned `print` repository:
```bash
GITLAB_URL=https://gitlab01.<your-lan> GITLAB_TOKEN=… \
VAULT_ADDR=https://<your-vault>:8200 CF_ACCOUNT_ID=… \
ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com \
  LifeChart/infra/bootstrap-gitlab.sh
```
It creates the private project, prints its path (for step 3), and prints how to
register the homelab runner (shell executor, in the `docker` group, with
`rsync`) and prepare `/opt/lifechart`. If gitlab01 uses an internal CA, add
`GITLAB_CA_PEM=/path/to/ca.pem`.

### 3. Vault (once, as a Vault admin)
```bash
export VAULT_ADDR=https://<your-vault>:8200
vault login
GITLAB_URL=https://gitlab01.<your-lan> GITLAB_PROJECT=<user-or-group>/lifechart \
  LifeChart/infra/vault/setup.sh
```
Then store your secrets as the script prints:
```bash
vault kv put -mount=secret lifechart/ci cloudflare_api_token='…'
vault kv put -mount=secret lifechart/app \
  lifechart_api_token="$(openssl rand -hex 32)" anthropic_api_key='…'
```
If gitlab01 uses a private CA, pass `GITLAB_CA_PEM=/path/ca.pem` so Vault can
verify its JWT keys.

### 4. Run the pipeline
On gitlab01: **CI/CD → Pipelines** on `main`. Review `terraform:plan`, click ▶
on `terraform:apply`; `deploy:homelab` follows automatically.

### 5. The iPhone
```bash
vault kv get -mount=secret lifechart/cloudflare      # server_url, iphone_client_id, iphone_client_secret
vault kv get -mount=secret -field=lifechart_api_token lifechart/app
```
Enter them in the app under **More → Server & Cloudflare** and tap
**Save & test**.

## Rotating secrets
- **API token / Anthropic key**: `vault kv patch -mount=secret lifechart/app …`, rerun `deploy:homelab`, update the app.
- **iPhone service token**: `terraform apply -replace=cloudflare_zero_trust_access_service_token.iphone` (or taint it in the pipeline), then read the new values from Vault.
