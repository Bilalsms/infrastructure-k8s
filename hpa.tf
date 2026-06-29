// Horizontal Pod Autoscalers for hot-path services.
//
// Per CNAE A2 refactor plan: services that scaled with load (S2/S0 ratio > 2x
// in the vanilla baseline) get HPA so the cluster autoscaler has a reason to
// add a second node under peak. Trigger is CPU utilisation > 70% of the
// rightsized request (set in misarch-<svc>.tf), min=1, max=4.
//
// Not included:
//   * gateway — already runs as the federation entry-point; horizontal scale
//     of Mesh introduces schema-cache inconsistency across replicas. Keep at 1.
//   * dark-idle services — these are the KEDA scale-to-zero candidates, not
//     HPA candidates. See keda-scaledobjects.tf and FaaS analysis.
//
// Why 70 %: GKE's metrics-server resolution is ~30s; targeting 70 % gives the
// scaler time to react before the request rejection rate climbs. This matches
// GKE's documented best-practice for CPU-driven HPA.

locals {
  hpa_hotpath_targets = {
    catalog      = "misarch-catalog"
    order        = "misarch-order"
    shoppingcart = "misarch-shoppingcart"
    payment      = "misarch-payment"
    inventory    = "misarch-inventory"
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "hotpath" {
  for_each = local.hpa_hotpath_targets

  metadata {
    name      = "${each.value}-hpa"
    namespace = local.namespace
  }
  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = each.value
    }
    min_replicas = 1
    max_replicas = 4
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
    behavior {
      scale_down {
        stabilization_window_seconds = 300
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 60
        }
      }
      scale_up {
        stabilization_window_seconds = 30
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 30
        }
      }
    }
  }
}
