// Kepler — per-pod energy attribution via eBPF + RAPL
//
// Deployed as a DaemonSet in its own `kepler` namespace (consistent with
// cert-manager / opentelemetry-operator-system pattern). The ServiceMonitor
// is placed in the `misarch` namespace where the kube-prometheus-stack
// Prometheus discovers ServiceMonitors with `release=prometheus-stack`.

resource "kubernetes_namespace" "kepler" {
  metadata {
    name = "kepler"
  }
}

resource "helm_release" "kepler" {
  depends_on = [
    kubernetes_namespace.kepler,
    helm_release.prometheus_grafana_stack,
  ]

  // CROSS-NAMESPACE OWNERSHIP HAZARD
  //   This release lives in the `kepler` namespace but renders its
  //   ServiceMonitor into `misarch` (see values below). Deleting the misarch
  //   namespace therefore destroys the ServiceMonitor while leaving this
  //   release "deployed" and healthy — so a plain `terraform apply` sees
  //   nothing to do, Kepler keeps exporting metrics, and NOBODY SCRAPES THEM.
  //   The failure is silent: pods are green, Prometheus simply has zero
  //   kepler_container_joules_total and every energy dashboard is blank.
  //
  //   Replacing this release whenever the misarch namespace is recreated
  //   re-renders the ServiceMonitor. Costs one DaemonSet restart on rebuild;
  //   Kepler is stateless, so nothing is lost.
  //
  //   Verify after any rebuild:
  //     kubectl get servicemonitor -n misarch | grep kepler
  lifecycle {
    replace_triggered_by = [kubernetes_namespace.misarch]
  }
  name       = "kepler"
  repository = "https://sustainable-computing-io.github.io/kepler-helm-chart"
  chart      = "kepler"
  namespace  = "kepler"
  version    = "0.6.1"

  values = [
    <<-EOF
    # eBPF + cgroup access for accurate per-pod attribution.
    # GKE nodes block RAPL hardware counters; Kepler will auto-fall-back to
    # CPU-utilization × TDP estimation (see Master Plan §5 Fallback).
    canMountNS: true

    # Expose Kepler's /metrics so kube-prometheus-stack can scrape it.
    serviceMonitor:
      enabled: true
      namespace: ${local.namespace}
      labels:
        release: prometheus-stack
      interval: 15s

    # Conservative resources for a 16/64 node — Kepler is lightweight.
    resources:
      requests:
        cpu: "50m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
    EOF
  ]
}
