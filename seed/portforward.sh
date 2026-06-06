#!/usr/bin/env bash
# Start kubectl port-forwards for seed.py.
#   gateway  svc/misarch-gateway 8080 -> localhost:8080
#   keycloak svc/keycloak        80   -> localhost:8081
#
# Run in a separate terminal; Ctrl-C to stop.

set -euo pipefail
NS="${MISARCH_NAMESPACE:-misarch}"

PIDS=()
cleanup() {
  echo
  echo "stopping port-forwards"
  kill "${PIDS[@]:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

kubectl -n "$NS" port-forward svc/misarch-gateway       8080:8080 >/tmp/pf-gw.log    2>&1 &
PIDS+=($!)
kubectl -n "$NS" port-forward svc/keycloak              8081:80   >/tmp/pf-kc.log    2>&1 &
PIDS+=($!)
# Media service has no K8s Service — port-forward straight to the Deployment pod.
# GraphQL Mesh gateway does not federate media's Upload scalar, so seed.py
# uploads images directly to the media service at MEDIA_URL.
kubectl -n "$NS" port-forward deploy/misarch-media      9091:8080 >/tmp/pf-media.log 2>&1 &
PIDS+=($!)

sleep 2
echo "gateway:  http://localhost:8080/graphql"
echo "keycloak: http://localhost:8081/keycloak"
echo "media:    http://localhost:9091/         (GraphQL at /)"
echo "logs:     /tmp/pf-gw.log /tmp/pf-kc.log /tmp/pf-media.log"
echo "Ctrl-C to stop."
wait
