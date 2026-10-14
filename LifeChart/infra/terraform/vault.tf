# Secret layout in Vault (KV v2, mount var.vault_kv_mount):
#
#   lifechart/ci          you    cloudflare_api_token
#   lifechart/app         you    lifechart_api_token, anthropic_api_key,
#                                garmin_email, garmin_password (optional)
#   lifechart/cloudflare  Terraform  tunnel_token, access_aud, access_team_domain,
#                                iphone_client_id, iphone_client_secret, server_url

data "vault_kv_secret_v2" "ci" {
  mount = var.vault_kv_mount
  name  = "lifechart/ci"
}

resource "vault_kv_secret_v2" "cloudflare" {
  mount = var.vault_kv_mount
  name  = "lifechart/cloudflare"
  data_json = jsonencode({
    server_url           = "https://${var.hostname}"
    tunnel_token         = cloudflare_zero_trust_tunnel_cloudflared.lifechart.tunnel_token
    access_aud           = cloudflare_zero_trust_access_application.lifechart.aud
    access_team_domain   = var.access_team_domain
    iphone_client_id     = cloudflare_zero_trust_access_service_token.iphone.client_id
    iphone_client_secret = cloudflare_zero_trust_access_service_token.iphone.client_secret
  })
}
