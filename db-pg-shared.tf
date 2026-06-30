// Shared Postgres for the 8 misarch Spring services
// Saves ~1.6 cores vs one Postgres per service. 

// Schema strategy: one database per service, all owned by the same
// `misarch` user. Per-service isolation is at the database level; tables
// don't collide because each service runs its own Flyway migrations into
// its own database. Lower security isolation than per-service users, but
// the DB is in-cluster only and this is a measurement project.

resource "helm_release" "misarch_pg_shared" {
  name       = local.pg_shared_service_name
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "postgresql"
  namespace  = local.namespace

  values = [
    <<-EOF
    fullnameOverride: "${local.pg_shared_service_name}"
    auth:
      enablePostgresUser: true
      postgresPassword: "${random_password.misarch_pg_shared_root_password.result}"
      username: "${var.MISARCH_DB_USER}"
      database: "_bootstrap"   # placeholder; real DBs created by initdbScripts
      password: "${random_password.misarch_pg_shared_app_password.result}"
    metrics:
      enabled: true
    primary:
      # Single instance carrying 8 services worth of traffic — bump from
      # nano (used for the per-service Postgres releases) to small.
      # Observed pre-consolidation: 8 × ~30m CPU peak = ~240m steady state.
      resourcesPreset: small
      initdb:
        scripts:
          create-misarch-dbs.sql: |
            CREATE DATABASE address_db;       GRANT ALL PRIVILEGES ON DATABASE address_db       TO ${var.MISARCH_DB_USER};
            CREATE DATABASE catalog_db;       GRANT ALL PRIVILEGES ON DATABASE catalog_db       TO ${var.MISARCH_DB_USER};
            CREATE DATABASE discount_db;      GRANT ALL PRIVILEGES ON DATABASE discount_db      TO ${var.MISARCH_DB_USER};
            CREATE DATABASE notification_db;  GRANT ALL PRIVILEGES ON DATABASE notification_db  TO ${var.MISARCH_DB_USER};
            CREATE DATABASE return_db;        GRANT ALL PRIVILEGES ON DATABASE return_db        TO ${var.MISARCH_DB_USER};
            CREATE DATABASE shipment_db;      GRANT ALL PRIVILEGES ON DATABASE shipment_db      TO ${var.MISARCH_DB_USER};
            CREATE DATABASE tax_db;           GRANT ALL PRIVILEGES ON DATABASE tax_db           TO ${var.MISARCH_DB_USER};
            CREATE DATABASE user_db;          GRANT ALL PRIVILEGES ON DATABASE user_db          TO ${var.MISARCH_DB_USER};
    EOF
  ]
}
