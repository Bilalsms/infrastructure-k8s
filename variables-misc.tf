variable "KUBERNETES_CONFIG_PATH" {
  sensitive = true
  type      = string
  default   = "~/.kube/config"
}

variable "KUBERNETES_NAMESPACE" {
  type    = string
  default = "misarch"
}

variable "MISARCH_DB_USER" {
  type    = string
  default = "misarch"
}

variable "MISARCH_DB_DATABASE" {
  type    = string
  default = "misarch"
}

variable "KEYCLOAK_DB_USER" {
  type    = string
  default = "postgres"
}

variable "KEYCLOAK_DB_DATABASE" {
  type    = string
  default = "keycloak"
}

variable "INFLUXDB_USER" {
  type    = string
  default = "admin"
}

variable "INFLUXDB_PASSWORD" {
  type    = string
  default = "admin123"
}

variable "INFLUXDB_ORG" {
  type    = string
  default = "misarch"
}

variable "INFLUXDB_BUCKET" {
  type    = string
  default = "gatling"
}

variable "MISARCH_SIMULATION_PAYMENTS_PER_MINUTE" {
  type    = number
  default = 10000000
}

variable "MISARCH_SIMULATION_SHIPMENTS_PER_MINUTE" {
  type    = number
  default = 10000000
}

variable "MISARCH_SIMULATION_PROCESSING_TIME_SECONDS" {
  type    = number
  default = 5
}

variable "MONGODB_RESOURCE_PRESET" {
  type        = string
  description = "Sets a resource limit for MongoDBs. Values are as described in https://github.com/bitnami/charts/blob/4b89068b8267e4b115c676064d092a05813953cc/bitnami/common/templates/_resources.tpl#L16-L43. Default is 'micro', Helm Chart default was 'small'."
  default     = "micro"
}

variable "RABBITMQ_ERLANG_COOKIE" {
  type    = string
  default = "RABBITMQ_MISARCH_ERLANG_COOKIE"
}

// ---- Ingress / TLS -------------------------------------------------------
// GCP project and region — used by the google provider in main.tf and by
// `google_compute_address.misarch_ingress` in ingress-nginx.tf.
variable "GCP_PROJECT" {
  type        = string
  description = "GCP project ID hosting the GKE cluster."
}

variable "GCP_REGION" {
  type        = string
  description = "GCP region for the reserved LB IP. Must match the GKE cluster region."
  default     = "europe-west1"
}

variable "CERT_ISSUER" {
  type        = string
  description = "cert-manager ClusterIssuer to use for Ingress TLS. Currently only 'selfsigned-cluster' is supported; Let's Encrypt was removed because every public host in this project is under nip.io (shared registered domain) and would hit LE rate limits on reproduction runs."
  default     = "selfsigned-cluster"
  validation {
    condition     = var.CERT_ISSUER == "selfsigned-cluster"
    error_message = "CERT_ISSUER must be 'selfsigned-cluster'. Let's Encrypt support removed — see cert-issuers.tf for rationale."
  }
}

locals {
  dapr_general_config_name = "dapr-config"
}
