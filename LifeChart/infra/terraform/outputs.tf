# Secrets are written to Vault (see vault.tf), not exposed as outputs.

output "server_url" {
  description = "Enter this in the app: More → Server & Cloudflare → Server."
  value       = "https://${var.hostname}"
}

output "vault_path_for_iphone" {
  description = "Read the app's Cloudflare credentials with: vault kv get <this>."
  value       = "${var.vault_kv_mount}/lifechart/cloudflare"
}

output "access_aud" {
  description = "Application Audience tag of the Access application (not secret)."
  value       = cloudflare_zero_trust_access_application.lifechart.aud
}
