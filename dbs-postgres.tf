
resource "helm_release" "misarch_keycloak_db" {
  name       = local.keycloak_db_service_name
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "postgresql"
  namespace  = local.namespace

  values = [
    <<-EOF
    fullnameOverride: "${local.keycloak_db_service_name}"
    auth:
      enablePostgresUser: true
      postgresPassword: "${random_password.postgres_keycloak_db_password.result}"
      username: ${var.KEYCLOAK_DB_USER}
      database: ${var.KEYCLOAK_DB_DATABASE}
      password: "${random_password.keycloak_db_password.result}"
    primary:
      resourcesPreset: nano
    metrics:
      enabled: false
    EOF
  ]
}