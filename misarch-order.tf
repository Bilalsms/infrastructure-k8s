resource "kubernetes_deployment" "misarch_order" {
  depends_on = [helm_release.misarch_order_db, terraform_data.dapr]
  metadata {

    name      = local.misarch_order_service_name
    labels    = merge(local.base_misarch_labels, local.misarch_order_specific_labels)
    namespace = local.namespace
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = local.misarch_order_service_name
      }
    }

    template {
      metadata {
        labels      = merge(local.base_misarch_labels, local.misarch_order_specific_labels)
        annotations = merge(local.base_misarch_annotations, local.misarch_order_specific_annotations)
      }

      spec {

        container {
          image             = "ghcr.io/misarch/order:${var.MISARCH_ORDER_VERSION}"
          image_pull_policy = "Always"

          name = local.misarch_order_service_name


          resources {
            limits = {
              cpu    = "1500m"
              memory = "352Mi"
            }
            requests = {
              cpu    = "740m"
              memory = "192Mi"
            }
          }

          env_from {
            config_map_ref {
              name = local.misarch_base_env_vars_configmap
            }
          }
          env_from {
            config_map_ref {
              name = local.misarch_order_env_vars_configmap
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
              name = local.misarch_order_ecs_env_vars_configmap
            }
          }
        }
      }
    }
  }
}
