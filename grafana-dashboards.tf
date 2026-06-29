// Grafana dashboards loaded via the kube-prometheus-stack Grafana sidecar.
// Any ConfigMap in the misarch namespace with label `grafana_dashboard=1`
// is auto-discovered and mounted into Grafana.
// To see ALL pods, set the
// $namespace and $pod dashboard variables to `.*`.

resource "kubernetes_config_map" "kepler_dashboard" {
  metadata {
    name      = "kepler-exporter-dashboard"
    namespace = local.namespace
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "kepler-exporter.json" = file("${path.module}/dashboards/kepler-exporter.json")
  }
}

resource "kubernetes_config_map" "cnae_energy_dashboard" {
  metadata {
    name      = "cnae-energy-dashboard"
    namespace = local.namespace
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "cnae-energy.json" = file("${path.module}/dashboards/cnae-energy.json")
  }
}
