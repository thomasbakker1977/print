variable "zone_name" {
  description = "Domain in Cloudflare that hosts the LifeChart hostname."
  type        = string
  default     = "datafor.business"
}

variable "hostname" {
  description = "Public hostname for the LifeChart API."
  type        = string
  default     = "lifechart.datafor.business"
}

variable "admin_emails" {
  description = "E-mail addresses allowed to open the API in a browser (one-time PIN login). Empty = service token only."
  type        = list(string)
  default     = []
}

variable "service_token_duration" {
  description = "How long the iPhone's Cloudflare service token stays valid."
  type        = string
  default     = "8760h"
}

variable "vault_kv_mount" {
  description = "KV version 2 mount that holds the LifeChart secrets."
  type        = string
  default     = "secret"
}
