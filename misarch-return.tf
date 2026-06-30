resource "kubernetes_deployment" "misarch_return" {
  depends_on = [helm_release.misarch_pg_shared, terraform_data.dapr]
  metadata {

    name      = local.misarch_return_service_name
    labels    = merge(local.base_misarch_labels, local.misarch_return_specific_labels)
    namespace = local.namespace
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = local.misarch_return_service_name
      }
    }

    template {
      metadata {
        labels      = merge(local.base_misarch_labels, local.misarch_return_specific_labels)
        annotations = merge(local.base_misarch_annotations, local.misarch_return_specific_annotations)
      }

      spec {

        container {
          image             = "ghcr.io/misarch/return:${var.MISARCH_RETURN_VERSION}"
          image_pull_policy = "Always"

          name = local.misarch_return_service_name

          resources {
            limits = {
              cpu    = "200m"
              memory = "1408Mi"
            }
            requests = {
              cpu    = "60m"
              memory = "800Mi"
            }
          }

          env_from {
            config_map_ref {
              name = local.misarch_base_env_vars_configmap
            }
          }
          env_from {
            config_map_ref {
              name = local.misarch_return_env_vars_configmap
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
              name = local.misarch_return_ecs_env_vars_configmap
            }
          }
        }
      }
    }
  }
}
