// Instrumentation CR — tells the OTel Operator which SDK image to inject and
// where injected pods should export their traces.

resource "kubectl_manifest" "misarch_nodejs_instrumentation" {
  depends_on = [helm_release.opentelemetry_operator]
  yaml_body  = <<-YAML
    apiVersion: opentelemetry.io/v1alpha1
    kind: Instrumentation
    metadata:
      name: misarch-nodejs
      namespace: ${local.namespace}
    spec:
      exporter:
        endpoint: http://${local.otel_collector_url_http}
      propagators:
        - tracecontext
        - baggage
      sampler:
        type: parentbased_traceidratio
        argument: "1.0"
      nodejs:
        image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.76.0
  YAML
}
