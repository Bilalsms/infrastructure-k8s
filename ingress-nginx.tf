resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
  }
}

resource "google_compute_address" "misarch_ingress" {
  name         = "misarch-ingress-lb"
  region       = var.GCP_REGION
  address_type = "EXTERNAL"
  network_tier = "STANDARD"
  description  = "Static IP for ingress-nginx LoadBalancer — managed by Terraform"

  lifecycle {
    ignore_changes = [description]
  }
}

locals {
  ingress_base_host = "${google_compute_address.misarch_ingress.address}.nip.io"
}

resource "helm_release" "ingress_nginx" {
  depends_on = [kubernetes_namespace.ingress_nginx, google_compute_address.misarch_ingress]
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "ingress-nginx"
  version    = "4.11.3"

  values = [
    <<-EOF
    controller:
      replicaCount: 1
      # Single regional LB. externalTrafficPolicy=Local preserves client IP for logs/rate-limit
      service:
        type: LoadBalancer
        externalTrafficPolicy: Local
        loadBalancerIP: ${google_compute_address.misarch_ingress.address}
        annotations:
          # Force a regional (not premium global) tier — cheaper, fine for measurement.
          cloud.google.com/network-tier: "Standard"
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 500m
          memory: 512Mi
      # Allow large file uploads (catalog seeder pushes product images via /api/media).
      config:
        proxy-body-size: "20m"
        proxy-buffer-size: "16k"
        use-forwarded-headers: "true"
        hsts: "true"
        hsts-include-subdomains: "true"
      metrics:
        enabled: true
        serviceMonitor:
          enabled: false
      admissionWebhooks:
        enabled: true
    defaultBackend:
      enabled: false
    EOF
  ]
}

// Expose the LB IP so other modules + the operator can find it.
data "kubernetes_service" "ingress_nginx_controller" {
  depends_on = [helm_release.ingress_nginx]
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }
}

output "ingress_load_balancer_ip" {
  description = "Public IP of the ingress-nginx LoadBalancer. Point DNS A records here, or use <ip>.nip.io."
  value = try(
    data.kubernetes_service.ingress_nginx_controller.status[0].load_balancer[0].ingress[0].ip,
    "<pending — re-run terraform refresh after the LB provisions>"
  )
}

output "ingress_hosts" {
  description = "Hostnames the ingress will serve once DNS resolves to the LB IP."
  // Single source of truth: local.ingress_hosts in ingress.tf.
  value = local.ingress_hosts
}
