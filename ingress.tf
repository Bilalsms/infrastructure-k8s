// External routing for every service the operator / users need to reach.
//
// One nginx-ingress controller (see ingress-nginx.tf) fronts everything.
// Hostnames are built from var.INGRESS_BASE_HOST so the operator can flip the whole
// fleet to e.g. "<lb-ip>.nip.io" without editing this file.
//
// Each Ingress carries `cert-manager.io/cluster-issuer` so cert-manager auto-issues
// a TLS secret. Default issuer is self-signed (zero DNS required)

locals {
  ingress_class = "nginx"
  issuer        = var.CERT_ISSUER

  ingress_hosts = {
    frontend   = "misarch.${var.INGRESS_BASE_HOST}"
    gateway    = "api.misarch.${var.INGRESS_BASE_HOST}"
    keycloak   = "auth.misarch.${var.INGRESS_BASE_HOST}"
    grafana    = "grafana.misarch.${var.INGRESS_BASE_HOST}"
    prometheus = "prometheus.misarch.${var.INGRESS_BASE_HOST}"
    minio      = "minio.misarch.${var.INGRESS_BASE_HOST}"
  }

  common_ingress_annotations = {
    "cert-manager.io/cluster-issuer"                 = local.issuer
    "nginx.ingress.kubernetes.io/ssl-redirect"       = "true"
    "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"
    "nginx.ingress.kubernetes.io/proxy-body-size"    = "20m"
    "nginx.ingress.kubernetes.io/proxy-buffer-size"  = "16k"
  }
}

resource "kubernetes_service" "misarch_frontend_service" {
  metadata {
    name      = local.misarch_frontend_service_name
    namespace = local.namespace
    labels    = merge(local.base_misarch_labels, local.misarch_frontend_specific_labels)
  }

  spec {
    selector = { app = local.misarch_frontend_service_name }

    port {
      protocol    = "TCP"
      port        = local.frontend_port
      target_port = local.frontend_port
    }

    type = "ClusterIP"
  }
}

// ---------- Frontend (shop UI) ----------
resource "kubernetes_ingress_v1" "misarch_frontend" {
  depends_on = [helm_release.ingress_nginx]
  metadata {
    name        = local.ingress_name
    namespace   = local.namespace
    annotations = local.common_ingress_annotations
  }
  spec {
    ingress_class_name = local.ingress_class

    tls {
      hosts       = [local.ingress_hosts.frontend]
      secret_name = "tls-misarch-frontend"
    }

    rule {
      host = local.ingress_hosts.frontend
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = local.misarch_frontend_service_name
              port { number = local.frontend_port }
            }
          }
        }
      }
    }
  }
}

// ---------- Gateway (GraphQL federation entrypoint) ----------
// k6 scripts and external API clients hit this directly.
resource "kubernetes_ingress_v1" "misarch_gateway" {
  depends_on = [helm_release.ingress_nginx]
  metadata {
    name      = "misarch-gateway-ingress"
    namespace = local.namespace
    annotations = merge(local.common_ingress_annotations, {
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "120"
      "nginx.ingress.kubernetes.io/proxy-send-timeout" = "120"
    })
  }
  spec {
    ingress_class_name = local.ingress_class

    tls {
      hosts       = [local.ingress_hosts.gateway]
      secret_name = "tls-misarch-gateway"
    }

    rule {
      host = local.ingress_hosts.gateway
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = local.misarch_gateway_service_name
              // Gateway exposes 8080 internally; service maps it to 8080 too.
              port { number = 8080 }
            }
          }
        }
      }
    }
  }
}

// ---------- Keycloak (OIDC + admin console) ----------
// Public entry on auth.misarch.<host>. Keycloak itself canonicalises to the
// shop origin via KC_HOSTNAME so users landing here get redirected to
// misarch.<host>/keycloak/... — by design (cookie + CORS first-party).
resource "kubernetes_ingress_v1" "keycloak" {
  depends_on = [helm_release.ingress_nginx]
  metadata {
    name      = "keycloak-ingress"
    namespace = local.namespace
    annotations = merge(local.common_ingress_annotations, {
      // Keycloak admin console pushes big cookies; bump header buffers.
      "nginx.ingress.kubernetes.io/proxy-buffer-size" = "32k"
    })
  }
  spec {
    ingress_class_name = local.ingress_class

    tls {
      hosts       = [local.ingress_hosts.keycloak]
      secret_name = "tls-keycloak"
    }

    rule {
      host = local.ingress_hosts.keycloak
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = local.keycloak_service_name
              port { number = local.keycloak_port }
            }
          }
        }
      }
    }
  }
}

// ---------- Grafana (Kepler dashboards) ----------
resource "kubernetes_ingress_v1" "grafana" {
  depends_on = [helm_release.ingress_nginx, helm_release.prometheus_grafana_stack]
  metadata {
    name        = "grafana-ingress"
    namespace   = local.namespace
    annotations = local.common_ingress_annotations
  }
  spec {
    ingress_class_name = local.ingress_class

    tls {
      hosts       = [local.ingress_hosts.grafana]
      secret_name = "tls-grafana"
    }

    rule {
      host = local.ingress_hosts.grafana
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "prometheus-stack-grafana"
              port { number = 80 }
            }
          }
        }
      }
    }
  }
}

// ---------- Prometheus (PromQL exploration / k6 metric pulls) ----------
// No auth on the UI — this exposes raw metrics. Acceptable for a measurement cluster;
// for shared / public deployments, layer a basic-auth annotation on top.
resource "kubernetes_ingress_v1" "prometheus" {
  depends_on = [helm_release.ingress_nginx, helm_release.prometheus_grafana_stack]
  metadata {
    name        = "prometheus-ingress"
    namespace   = local.namespace
    annotations = local.common_ingress_annotations
  }
  spec {
    ingress_class_name = local.ingress_class

    tls {
      hosts       = [local.ingress_hosts.prometheus]
      secret_name = "tls-prometheus"
    }

    rule {
      host = local.ingress_hosts.prometheus
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              // kube-prometheus-stack default service name.
              name = "prometheus-stack-kube-prom-prometheus"
              port { number = 9090 }
            }
          }
        }
      }
    }
  }
}

// ---------- MinIO console (object storage) ----------
resource "kubernetes_ingress_v1" "minio" {
  depends_on = [helm_release.ingress_nginx]
  metadata {
    name        = "minio-ingress"
    namespace   = local.namespace
    annotations = local.common_ingress_annotations
  }
  spec {
    ingress_class_name = local.ingress_class

    tls {
      hosts       = [local.ingress_hosts.minio]
      secret_name = "tls-minio"
    }

    rule {
      host = local.ingress_hosts.minio
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = local.minio_service_name
              port { number = local.minio_port }
            }
          }
        }
      }
    }
  }
}
