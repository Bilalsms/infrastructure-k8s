// KEDA ScaledObjects — scale-to-zero on async/cron-driven services.
// Applied via kubectl_manifest because terraform's kubernetes_manifest needs
// the CRDs to exist at plan time, which fails on a fresh apply before KEDA's
// helm release runs. kubectl_manifest defers CRD validation until apply.

// ─── experiment-config: PoC, cron trigger, always 0 ──────────────────────
resource "kubectl_manifest" "scaledobject_experiment_config" {
  depends_on = [helm_release.keda]

  yaml_body = <<-YAML
    apiVersion: keda.sh/v1alpha1
    kind: ScaledObject
    metadata:
      name: experiment-config-scaler
      namespace: ${local.namespace}
    spec:
      scaleTargetRef:
        name: misarch-experiment-config
      minReplicaCount: 0
      maxReplicaCount: 1
      pollingInterval: 30
      cooldownPeriod: 300
      triggers:
        - type: cron
          metadata:
            timezone: UTC
            # Never wake automatically — use the paused-replicas annotation to
            # force a temporary scale-up when an admin needs the service.
            start: "0 0 31 2 *"
            end:   "5 0 31 2 *"
            desiredReplicas: "1"
  YAML
}
