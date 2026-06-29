resource "kubernetes_deployment" "misarch_shoppingcart" {
  depends_on = [helm_release.misarch_shoppingcart_db, terraform_data.dapr]
  metadata {

    name      = local.misarch_shoppingcart_service_name
    labels    = merge(local.base_misarch_labels, local.misarch_shoppingcart_specific_labels)
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
        app = local.misarch_shoppingcart_service_name
      }
    }

    template {
      metadata {
        labels      = merge(local.base_misarch_labels, local.misarch_shoppingcart_specific_labels)
        annotations = merge(local.base_misarch_annotations, local.misarch_shoppingcart_specific_annotations)
      }

      spec {

        container {
          image             = "ghcr.io/misarch/shoppingcart:${var.MISARCH_SHOPPINGCART_VERSION}"
          image_pull_policy = "Always"

          name = local.misarch_shoppingcart_service_name


          resources {
            limits = {
              cpu    = "700m"
              memory = "288Mi"
            }
            requests = {
              cpu    = "340m"
              memory = "160Mi"
            }
          }

          env_from {
            config_map_ref {
              name = local.misarch_base_env_vars_configmap
            }
          }
          env_from {
            config_map_ref {
              name = local.misarch_shoppingcart_env_vars_configmap
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
              name = local.misarch_shoppingcart_ecs_env_vars_configmap
            }
          }
        }
      }
    }
  }
}
