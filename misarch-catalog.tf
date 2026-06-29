resource "kubernetes_deployment" "misarch_catalog" {
  depends_on = [helm_release.misarch_catalog_db, terraform_data.dapr]
  metadata {

    name      = local.misarch_catalog_service_name
    labels    = merge(local.base_misarch_labels, local.misarch_catalog_specific_labels)
    namespace = local.namespace
  }

  // HPA owns replicas (see hpa.tf). Without ignore_changes, every `terraform
  // apply` would reset replicas to 1 and the HPA would immediately scale it
  // back up — perpetual diff and pod churn that contaminates energy readings.
  lifecycle {
    ignore_changes = [spec[0].replicas]
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = local.misarch_catalog_service_name
      }
    }

    template {
      metadata {
        labels      = merge(local.base_misarch_labels, local.misarch_catalog_specific_labels)
        annotations = merge(local.base_misarch_annotations, local.misarch_catalog_specific_annotations)
      }

      spec {

        container {
          image             = "ghcr.io/misarch/catalog:${var.MISARCH_CATALOG_VERSION}"
          image_pull_policy = "Always"

          name = local.misarch_catalog_service_name

          resources {
            limits = {
              cpu    = "900m"
              memory = "2464Mi"
            }
            requests = {
              cpu    = "440m"
              memory = "1392Mi"
            }
          }

          env_from {
            config_map_ref {
              name = local.misarch_base_env_vars_configmap
            }
          }
          env_from {
            config_map_ref {
              name = local.misarch_catalog_env_vars_configmap
            }
          }
        }

        container {
          image             = "ghcr.io/misarch/experiment-config-sidecar:${var.MISARCH_EXPERIMENT_CONFIG_SIDECAR_VERSION}"
          image_pull_policy = "Always"

          name = local.misarch_ecs_service_name

          resources {
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "80Mi"
            }
          }

          env_from {
            config_map_ref {
              name = local.misarch_catalog_ecs_env_vars_configmap
            }
          }
        }
      }
    }
  }
}
