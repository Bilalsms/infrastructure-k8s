// KEDA — event-driven autoscaler, used by CNAE refactor to scale-to-zero
// async/cron-driven services (experiment-config, tax, notification).
// Installed in its own namespace so the operator lifecycle is independent of
// misarch app churn.

resource "kubernetes_namespace" "keda" {
  metadata {
    name = "keda"
    labels = {
      "managed-by" = "terraform"
    }
  }
}

resource "helm_release" "keda" {
  depends_on = [kubernetes_namespace.keda]

  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  namespace  = kubernetes_namespace.keda.metadata[0].name
  version    = "2.15.1"
}
