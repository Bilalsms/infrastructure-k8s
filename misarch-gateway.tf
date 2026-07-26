resource "kubernetes_service" "misarch_gateway" {
  metadata {
    name      = local.misarch_gateway_service_name
    labels    = merge(local.base_misarch_labels, local.misarch_gateway_specific_labels)
    namespace = local.namespace
  }

  spec {
    selector = {
      app = local.misarch_gateway_service_name
    }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

resource "kubernetes_deployment" "misarch_gateway" {
  depends_on = [terraform_data.dapr]
  metadata {

    name      = local.misarch_gateway_service_name
    labels    = merge(local.base_misarch_labels, local.misarch_gateway_specific_labels)
    namespace = local.namespace
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = local.misarch_gateway_service_name
      }
    }

    template {
      metadata {
        labels      = merge(local.base_misarch_labels, local.misarch_gateway_specific_labels)
        annotations = merge(local.base_misarch_annotations, local.misarch_gateway_specific_annotations)
      }

      spec {

        container {
          // Gateway refactor:
          //   * response cache plugin (envelopPlugins.ts)
          //   * JWT verification cache (envelopPlugins.ts)
          //   * OTel auto → http-only (otlp.js)
          //   * playground disabled (.meshrc.yaml)
          // Custom image; revert to ghcr.io upstream by changing tag back.
          // image             = "ghcr.io/misarch/gateway:${var.MISARCH_GATEWAY_VERSION}"
          image             = "europe-west1-docker.pkg.dev/misarch/misarch/gateway:cnae-gateway-slim"
          image_pull_policy = "Always"

          name = local.misarch_gateway_service_name

          resources {
            limits = {
              cpu    = "1550m"
              memory = "9600Mi"
            }
            requests = {
              cpu    = "770m"
              memory = "5472Mi"
            }
          }

          // Gateway: cap V8 old-gen heap to 512 MiB. Without this,
          // V8 sizes itself against the cgroup limit (9.6 GiB) and runs longer,
          env {
            name  = "NODE_OPTIONS"
            value = "--max-old-space-size=512"
          }

          readiness_probe {
            tcp_socket {
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            failure_threshold     = 3
            success_threshold     = 1
            timeout_seconds       = 5
          }

          env_from {
            config_map_ref {
              name = local.misarch_base_env_vars_configmap
            }
          }
          env_from {
            config_map_ref {
              name = local.misarch_gateway_env_vars_configmap
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
              name = local.misarch_gateway_ecs_env_vars_configmap
            }
          }
        }
      }
    }
  }
}
