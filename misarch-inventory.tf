resource "kubernetes_deployment" "misarch_inventory" {
  depends_on = [helm_release.misarch_inventory_db, terraform_data.dapr]
  metadata {

    name      = local.misarch_inventory_service_name
    labels    = merge(local.base_misarch_labels, local.misarch_inventory_specific_labels)
    namespace = local.namespace
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = local.misarch_inventory_service_name
      }
    }

    template {
      metadata {
        labels      = merge(local.base_misarch_labels, local.misarch_inventory_specific_labels)
        annotations = merge(local.base_misarch_annotations, local.misarch_inventory_specific_annotations)
      }

      spec {

        container {
          // Upstream image (`ghcr.io/misarch/inventory:${var.MISARCH_INVENTORY_VERSION}`) ships
          // with a Dapr pubsub key typo (`pubsubname` lowercase) that silently drops every event
          // and leaves inventory unable to observe ProductVariantVersion creates → checkout fails
          // with "ProductVariant not found". Custom build pins the corrected `pubSubName`.
          // Source diff: https://github.com/Misarch/inventory (file: src/events/index.ts).
          // Remove this override once upstream merges the fix.
          // image             = "ghcr.io/misarch/inventory:${var.MISARCH_INVENTORY_VERSION}"
          image = "europe-west1-docker.pkg.dev/misarch/misarch/inventory:cnae-pubsubname-fix"
          image_pull_policy = "Always"

          name = local.misarch_inventory_service_name


          resources {
            limits = {
              cpu    = "300m"
              memory = "896Mi"
            }
            requests = {
              cpu    = "150m"
              memory = "496Mi"
            }
          }

          env_from {
            config_map_ref {
              name = local.misarch_base_env_vars_configmap
            }
          }
          env_from {
            config_map_ref {
              name = local.misarch_inventory_env_vars_configmap
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
              name = local.misarch_inventory_ecs_env_vars_configmap
            }
          }
        }
      }
    }
  }
}
