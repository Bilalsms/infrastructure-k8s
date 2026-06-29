// cert-manager — required by the OpenTelemetry Operator for its mutating-webhook TLS certs.

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "cert_manager" {
  depends_on = [kubernetes_namespace.cert_manager]
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  namespace  = "cert-manager"
  version    = "1.18.0"

  values = [
    <<-EOF
    crds:
      enabled: true
    EOF
  ]
}
