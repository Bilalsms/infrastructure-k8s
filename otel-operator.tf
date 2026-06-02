// OpenTelemetry Operator — auto-injects the OTel SDK into pods labeled with
// `instrumentation.opentelemetry.io/inject-<lang>` annotations.

resource "kubernetes_namespace" "opentelemetry_operator_system" {
  metadata {
    name = "opentelemetry-operator-system"
  }
}

resource "helm_release" "opentelemetry_operator" {
  depends_on = [
    kubernetes_namespace.opentelemetry_operator_system,
    helm_release.cert_manager,
  ]
  name       = "opentelemetry-operator"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-operator"
  namespace  = "opentelemetry-operator-system"
  version    = "0.70.0"

  values = [
    <<-EOF
    crds:
      create: true
    manager:
      collectorImage:
        repository: "otel/opentelemetry-collector-k8s"
    admissionWebhooks:
      certManager:
        enabled: true
    EOF
  ]
}
