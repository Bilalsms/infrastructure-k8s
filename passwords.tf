// Passwords
resource "random_password" "keycloak_db_password" {
  length  = 32
  special = false
}

resource "random_password" "minio_admin_password" {
  length  = 32
  special = false
}

resource "random_password" "prometheus_basic_auth_password" {
  length  = 32
  special = false
}

// Shared Postgres for the 8 misarch Spring services (path 3 consolidation).
// One root password (rotated by random_password) + one app user password.
// All 8 services connect with the same app credentials to per-service DBs.
resource "random_password" "misarch_pg_shared_root_password" {
  length  = 32
  special = false
}
resource "random_password" "misarch_pg_shared_app_password" {
  length  = 32
  special = false
}




resource "random_password" "misarch_inventory_db_password" {
  length  = 32
  special = false
}

resource "random_password" "misarch_invoice_db_password" {
  length  = 32
  special = false
}

resource "random_password" "misarch_media_db_password" {
  length  = 32
  special = false
}


resource "random_password" "misarch_order_db_password" {
  length  = 32
  special = false
}

resource "random_password" "misarch_payment_db_password" {
  length  = 32
  special = false
}

resource "random_password" "misarch_review_db_password" {
  length  = 32
  special = false
}



resource "random_password" "misarch_shoppingcart_db_password" {
  length  = 32
  special = false
}



resource "random_password" "misarch_wishlist_db_password" {
  length  = 32
  special = false
}









resource "random_password" "postgres_keycloak_db_password" {
  length  = 32
  special = false
}

resource "random_password" "rabbitmq_password" {
  length  = 32
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}




// Ouputs for these passwords




output "keycloak_db_password" {
  value     = random_password.keycloak_db_password.result
  sensitive = true
}

output "prometheus_basic_auth_password" {
  value     = random_password.prometheus_basic_auth_password.result
  sensitive = true
}

output "misarch_pg_shared_root_password" {
  value     = random_password.misarch_pg_shared_root_password.result
  sensitive = true
}

output "misarch_pg_shared_app_password" {
  value     = random_password.misarch_pg_shared_app_password.result
  sensitive = true
}

output "minio_admin_password" {
  value     = random_password.minio_admin_password.result
  sensitive = true
}




output "misarch_inventory_db_password" {
  value     = random_password.misarch_inventory_db_password.result
  sensitive = true
}

output "misarch_invoice_db_password" {
  value     = random_password.misarch_invoice_db_password.result
  sensitive = true
}

output "misarch_media_db_password" {
  value     = random_password.misarch_media_db_password.result
  sensitive = true
}


output "misarch_order_db_password" {
  value     = random_password.misarch_order_db_password.result
  sensitive = true
}

output "misarch_payment_db_password" {
  value     = random_password.misarch_payment_db_password.result
  sensitive = true
}

output "misarch_review_db_password" {
  value     = random_password.misarch_review_db_password.result
  sensitive = true
}



output "misarch_shoppingcart_db_password" {
  value     = random_password.misarch_shoppingcart_db_password.result
  sensitive = true
}



output "misarch_wishlist_db_password" {
  value     = random_password.misarch_wishlist_db_password.result
  sensitive = true
}









output "postgres_keycloak_db_password" {
  value     = random_password.postgres_keycloak_db_password.result
  sensitive = true
}

output "rabbitmq_password" {
  value     = random_password.rabbitmq_password.result
  sensitive = true
}

output "redis_password" {
  value     = random_password.redis.result
  sensitive = true
}

