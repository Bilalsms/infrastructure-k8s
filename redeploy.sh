#!/bin/bash
set -e

# Strip macOS quarantine from provider binaries so they can execute
if [[ "$(uname)" == "Darwin" ]]; then
  xattr -dr com.apple.quarantine .terraform/providers/ 2>/dev/null || true
fi

NAMESPACE="${TF_VAR_KUBERNETES_NAMESPACE:-misarch}"
VARFILE="latest-deployment.tfvars"

# Read state once — avoids 40+ individual "terraform state show" subprocess calls
echo "==> Reading current Terraform state..."
CURRENT_STATE=$(terraform state list 2>/dev/null || true)

import_if_missing() {
  local resource="$1"
  local id="$2"
  if ! echo "$CURRENT_STATE" | grep -qx "$resource"; then
    echo "  importing $resource ..."
    if terraform import -var-file="$VARFILE" "$resource" "$id" 2>/dev/null; then
      CURRENT_STATE="${CURRENT_STATE}"$'\n'"$resource"
    else
      echo "  (skipped — not present in cluster yet)"
    fi
  fi
}

echo "==> Cleaning up cluster-scoped leftovers from prior runs..."
# Cluster-scoped resources don't get deleted by `kubectl delete namespace`,
# so they survive and collide with the next apply. Wipe them so TF can recreate.
kubectl delete clusterrole \
  misarch-chaostoolkit-executor \
  otel-collector-prometheus-sd \
  --ignore-not-found
kubectl delete clusterrolebinding \
  misarch-chaostoolkit-executor-binding \
  otel-collector-prometheus-sd \
  --ignore-not-found

echo "==> Importing existing helm releases..."
import_if_missing "helm_release.redis"                    "${NAMESPACE}/redis"
import_if_missing "helm_release.dapr"                     "${NAMESPACE}/dapr"
import_if_missing "helm_release.influxdb"                 "${NAMESPACE}/influxdb"
import_if_missing "helm_release.prometheus_grafana_stack" "${NAMESPACE}/prometheus-stack"
import_if_missing 'helm_release.otel-collector'           "${NAMESPACE}/otel-collector"
import_if_missing "helm_release.minio"                    "${NAMESPACE}/minio"
import_if_missing "helm_release.misarch_address_db"       "${NAMESPACE}/address-db"
import_if_missing "helm_release.misarch_catalog_db"       "${NAMESPACE}/catalog-db"
import_if_missing "helm_release.misarch_discount_db"      "${NAMESPACE}/discount-db"
import_if_missing "helm_release.misarch_notification_db"  "${NAMESPACE}/notification-db"
import_if_missing "helm_release.misarch_return_db"        "${NAMESPACE}/return-db"
import_if_missing "helm_release.misarch_shipment_db"      "${NAMESPACE}/shipment-db"
import_if_missing "helm_release.misarch_tax_db"           "${NAMESPACE}/tax-db"
import_if_missing "helm_release.misarch_user_db"          "${NAMESPACE}/user-db"
import_if_missing "helm_release.misarch_keycloak_db"      "${NAMESPACE}/keycloak-db"
import_if_missing "helm_release.misarch_inventory_db"     "${NAMESPACE}/inventory-db"
import_if_missing "helm_release.misarch_invoice_db"       "${NAMESPACE}/invoice-db"
import_if_missing "helm_release.misarch_media_db"         "${NAMESPACE}/media-db"
import_if_missing "helm_release.misarch_order_db"         "${NAMESPACE}/order-db"
import_if_missing "helm_release.misarch_payment_db"       "${NAMESPACE}/payment-db"
import_if_missing "helm_release.misarch_review_db"        "${NAMESPACE}/review-db"
import_if_missing "helm_release.misarch_shoppingcart_db"  "${NAMESPACE}/shoppingcart-db"
import_if_missing "helm_release.misarch_wishlist_db"      "${NAMESPACE}/wishlist-db"

echo "==> Importing existing kubernetes deployments..."
import_if_missing "kubernetes_deployment.keycloak"                              "${NAMESPACE}/keycloak"
import_if_missing "kubernetes_deployment.minio"                                 "${NAMESPACE}/minio"
import_if_missing "kubernetes_deployment.rabbitmq"                              "${NAMESPACE}/rabbitmq"
import_if_missing "kubernetes_deployment.misarch_address"                       "${NAMESPACE}/misarch-address"
import_if_missing "kubernetes_deployment.misarch_catalog"                       "${NAMESPACE}/misarch-catalog"
import_if_missing "kubernetes_deployment.misarch_discount"                      "${NAMESPACE}/misarch-discount"
import_if_missing "kubernetes_deployment.misarch_frontend"                      "${NAMESPACE}/misarch-frontend"
import_if_missing "kubernetes_deployment.misarch_gateway"                       "${NAMESPACE}/misarch-gateway"
import_if_missing "kubernetes_deployment.misarch_inventory"                     "${NAMESPACE}/misarch-inventory"
import_if_missing "kubernetes_deployment.misarch_invoice"                       "${NAMESPACE}/misarch-invoice"
import_if_missing "kubernetes_deployment.misarch_media"                         "${NAMESPACE}/misarch-media"
import_if_missing "kubernetes_deployment.misarch_notification"                  "${NAMESPACE}/misarch-notification"
import_if_missing "kubernetes_deployment.misarch_order"                         "${NAMESPACE}/misarch-order"
import_if_missing "kubernetes_deployment.misarch_payment"                       "${NAMESPACE}/misarch-payment"
import_if_missing "kubernetes_deployment.misarch_return"                        "${NAMESPACE}/misarch-return"
import_if_missing "kubernetes_deployment.misarch_review"                        "${NAMESPACE}/misarch-review"
import_if_missing "kubernetes_deployment.misarch_shipment"                      "${NAMESPACE}/misarch-shipment"
import_if_missing "kubernetes_deployment.misarch_shoppingcart"                  "${NAMESPACE}/misarch-shoppingcart"
import_if_missing "kubernetes_deployment.misarch_simulation"                    "${NAMESPACE}/misarch-simulation"
import_if_missing "kubernetes_deployment.misarch_tax"                           "${NAMESPACE}/misarch-tax"
import_if_missing "kubernetes_deployment.misarch_user"                          "${NAMESPACE}/misarch-user"
import_if_missing "kubernetes_deployment.misarch_wishlist"                      "${NAMESPACE}/misarch-wishlist"
import_if_missing "kubernetes_deployment.misarch_experiment_config"             "${NAMESPACE}/misarch-experiment-config"
import_if_missing "kubernetes_deployment.misarch_experiment_config_frontend"    "${NAMESPACE}/misarch-experiment-config-frontend"
import_if_missing "kubernetes_deployment.misarch_experiment_executor"           "${NAMESPACE}/misarch-experiment-executor"
import_if_missing "kubernetes_deployment.misarch_experiment_executor_frontend"  "${NAMESPACE}/misarch-experiment-executor-frontend"
import_if_missing "kubernetes_deployment.misarch_gatling_executor"              "${NAMESPACE}/misarch-gatling-executor"
import_if_missing "kubernetes_deployment.misarch_chaostoolkit_executor"         "${NAMESPACE}/misarch-chaostoolkit-executor"

echo "==> Importing existing namespaces + configmaps (live-patched in prior sessions)..."
import_if_missing "kubernetes_namespace.ingress_nginx"                       "ingress-nginx"
import_if_missing "kubernetes_config_map.misarch_frontend_nginx_template"    "${NAMESPACE}/misarch-frontend-nginx-template"
import_if_missing "helm_release.ingress_nginx"                               "ingress-nginx/ingress-nginx"
import_if_missing "helm_release.cert_manager"                                "cert-manager/cert-manager"
import_if_missing "kubernetes_namespace.cert_manager"                        "cert-manager"
import_if_missing "kubernetes_namespace.kepler"                              "kepler"
import_if_missing "helm_release.kepler"                                      "kepler/kepler"

echo "==> Importing existing kubectl_manifest resources..."
import_if_missing 'kubectl_manifest.dapr_state_config'                        "dapr.io/v1alpha1//Component//statestore//misarch"
import_if_missing 'kubectl_manifest.dapr_pubsub_config'                       "dapr.io/v1alpha1//Component//pubsub//misarch"
import_if_missing 'kubectl_manifest.dapr_pubsub_config_experiment_config'     "dapr.io/v1alpha1//Component//experiment-config-pubsub//misarch"
import_if_missing 'kubectl_manifest.dapr_config'                              "dapr.io/v1alpha1//Configuration//dapr-config//misarch"

echo "==> Phase 1: Deploying redis + dapr (must be fully ready before services start)..."
terraform apply -var-file="$VARFILE" -auto-approve -refresh=false -parallelism=1 \
  -target=helm_release.redis \
  -target=helm_release.dapr \
  -target=terraform_data.dapr

echo "==> Phase 2: Deploying everything else..."
terraform apply -var-file="$VARFILE" -auto-approve -refresh=false -parallelism=3
