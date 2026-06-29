locals {
  rabbitmq_annotations = yamlencode(merge(local.base_misarch_annotations, local.rabbitmq_specific_annotations))
  rabbitmq_labels      = yamlencode(merge(local.base_misarch_labels, local.rabbitmq_specific_labels))
}

resource "kubernetes_config_map" "rabbitmq_enabled_plugins" {
  metadata {
    name      = "rabbitmq-enabled-plugins"
    namespace = local.namespace
  }

  data = {
    "enabled_plugins" = "[rabbitmq_management,rabbitmq_prometheus]."
  }
}

resource "kubernetes_deployment" "rabbitmq" {
  metadata {
    name      = local.rabbitmq_service_name
    namespace = local.namespace
    labels    = merge(local.base_misarch_labels, local.rabbitmq_specific_labels)
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = local.rabbitmq_service_name }
    }

    template {
      metadata {
        labels = merge(local.base_misarch_labels, local.rabbitmq_specific_labels)
        annotations = merge(local.base_misarch_annotations, local.rabbitmq_specific_annotations, {
          "prometheus.io/scrape" = "true"
          "prometheus.io/path"   = "/metrics"
          "prometheus.io/port"   = "15692"
        })
      }

      spec {
        container {
          name  = "rabbitmq"
          image = "rabbitmq:3-management"

          env {
            name  = "RABBITMQ_DEFAULT_USER"
            value = "guest"
          }
          env {
            name  = "RABBITMQ_DEFAULT_PASS"
            value = "guest"
          }
          env {
            name  = "RABBITMQ_DEFAULT_VHOST"
            value = "/"
          }
          env {
            name  = "RABBITMQ_ERLANG_COOKIE"
            value = var.RABBITMQ_ERLANG_COOKIE
          }

          env_from {
            config_map_ref {
              name = local.rabbitmq_env_vars_configmap
            }
          }

          port {
            name           = "amqp"
            container_port = 5672
          }
          port {
            name           = "management"
            container_port = 15672
          }
          port {
            name           = "prometheus"
            container_port = 15692
          }

          volume_mount {
            name       = "enabled-plugins"
            mount_path = "/etc/rabbitmq/enabled_plugins"
            sub_path   = "enabled_plugins"
          }
        }

        volume {
          name = "enabled-plugins"
          config_map {
            name = kubernetes_config_map.rabbitmq_enabled_plugins.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "rabbitmq" {
  metadata {
    name      = local.rabbitmq_service_name
    namespace = local.namespace
    labels    = merge(local.base_misarch_labels, local.rabbitmq_specific_labels)
  }

  spec {
    selector = { app = local.rabbitmq_service_name }

    port {
      name        = "amqp"
      port        = 5672
      target_port = 5672
    }
    port {
      name        = "management"
      port        = 15672
      target_port = 15672
    }
    port {
      name        = "prometheus"
      port        = 15692
      target_port = 15692
    }
  }
}
