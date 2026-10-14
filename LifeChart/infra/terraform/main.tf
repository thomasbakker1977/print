# LifeChart on Cloudflare: a tunnel to the homelab, a DNS record for it, and
# Cloudflare Access in front so only the iPhone (service token) and optional
# admins can reach the API.
#
#   iPhone ──HTTPS──▶ Cloudflare Access ──Tunnel──▶ cloudflared ──▶ lifechart:8080

data "cloudflare_zone" "this" {
  name = var.zone_name
}

# --- Tunnel -----------------------------------------------------------------

resource "random_id" "tunnel_secret" {
  byte_length = 35
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "lifechart" {
  account_id = local.cloudflare_account_id
  name       = "lifechart"
  secret     = random_id.tunnel_secret.b64_std
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "lifechart" {
  account_id = local.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.lifechart.id

  config {
    ingress_rule {
      hostname = var.hostname
      service  = "http://lifechart:8080"
    }
    # Everything else is refused.
    ingress_rule {
      service = "http_status:404"
    }
  }
}

resource "cloudflare_record" "lifechart" {
  zone_id = data.cloudflare_zone.this.id
  name    = var.hostname
  content = cloudflare_zero_trust_tunnel_cloudflared.lifechart.cname
  type    = "CNAME"
  proxied = true
  comment = "LifeChart API via Cloudflare Tunnel (managed by Terraform)"
}

# --- Access -----------------------------------------------------------------

resource "cloudflare_zero_trust_access_service_token" "iphone" {
  account_id = local.cloudflare_account_id
  name       = "lifechart-iphone"
  duration   = var.service_token_duration
}

resource "cloudflare_zero_trust_access_application" "lifechart" {
  zone_id                   = data.cloudflare_zone.this.id
  name                      = "LifeChart API"
  domain                    = var.hostname
  type                      = "self_hosted"
  session_duration          = "24h"
  app_launcher_visible      = false
  auto_redirect_to_identity = false
}

resource "cloudflare_zero_trust_access_policy" "iphone" {
  zone_id        = data.cloudflare_zone.this.id
  application_id = cloudflare_zero_trust_access_application.lifechart.id
  name           = "LifeChart iPhone (service token)"
  precedence     = 1
  decision       = "non_identity"

  include {
    service_token = [cloudflare_zero_trust_access_service_token.iphone.id]
  }
}

resource "cloudflare_zero_trust_access_policy" "admins" {
  count = length(var.admin_emails) > 0 ? 1 : 0

  zone_id        = data.cloudflare_zone.this.id
  application_id = cloudflare_zero_trust_access_application.lifechart.id
  name           = "LifeChart admins (browser)"
  precedence     = 2
  decision       = "allow"

  include {
    email = var.admin_emails
  }
}
