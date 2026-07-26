#!/usr/bin/env bash
# Fix Keycloak CORS for the split-origin MiSArch deployment.
#
# WHY THIS EXISTS
#   The realm template ships the `frontend` client with an empty `webOrigins`
#   list. The SPA is served from  misarch.<IP>.nip.io  while Keycloak lives on
#   auth.misarch.<IP>.nip.io, so every keycloak-js call is cross-origin. With no
#   allowed web origin the browser blocks the CORS preflight and the storefront's
#   Login button does nothing at all — no redirect, no error, no Keycloak page.
#   A permissive `redirectUris` does not help: redirect URIs and web origins are
#   enforced independently.
#
# USAGE
#   ./fix-keycloak-cors.sh [INGRESS_IP]
#
#   INGRESS_IP is optional — if omitted it is read from the ingress-nginx
#   LoadBalancer. Examples:
#       ./fix-keycloak-cors.sh
#       ./fix-keycloak-cors.sh 35.210.206.80
#
# Idempotent: safe to re-run. Verifies the fix and exits non-zero if the
# preflight does not come back correct.
#
# Overridable: NAMESPACE, REALM, CLIENT_ID
set -euo pipefail

NAMESPACE="${NAMESPACE:-misarch}"
REALM="${REALM:-Misarch}"
CLIENT_ID="${CLIENT_ID:-frontend}"
KCADM="/opt/keycloak/bin/kcadm.sh"
KC_LOCAL="http://localhost:8080/keycloak"   # Keycloak is served under /keycloak

die() { echo "ERROR: $*" >&2; exit 1; }

# ── 1. Resolve the ingress IP ───────────────────────────────────────────────
IP="${1:-}"
if [[ -z "$IP" ]]; then
  echo "==> No IP given — reading it from the ingress-nginx LoadBalancer..."
  IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n "$IP" ]] || die "could not detect the ingress IP. Pass it explicitly: $0 <IP>"
fi
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$IP' is not an IPv4 address"

SHOP="https://misarch.${IP}.nip.io"
API="https://api.misarch.${IP}.nip.io"
AUTH="https://auth.misarch.${IP}.nip.io"
echo "==> Ingress IP : $IP"
echo "    shop origin: $SHOP"
echo "    api  origin: $API"

# ── 2. Wait for Keycloak, then read the bootstrap admin credentials ─────────
kubectl -n "$NAMESPACE" get deploy keycloak >/dev/null 2>&1 \
  || die "deployment/keycloak not found in namespace '$NAMESPACE' — is the stack deployed?"

# Terraform invokes this immediately after creating the deployment, so wait for
# the realm import to finish before talking to kcadm.
echo "==> Waiting for Keycloak to become ready (up to ${ROLLOUT_TIMEOUT:-300}s)..."
kubectl -n "$NAMESPACE" rollout status deploy/keycloak \
  --timeout="${ROLLOUT_TIMEOUT:-300}s" >/dev/null \
  || die "keycloak deployment did not become ready in time"

ADMIN_USER=$(kubectl -n "$NAMESPACE" get secret keycloak-bootstrap \
  -o jsonpath='{.data.KEYCLOAK_ADMIN}' 2>/dev/null | base64 -d || true)
ADMIN_PW=$(kubectl -n "$NAMESPACE" get secret keycloak-bootstrap \
  -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' 2>/dev/null | base64 -d || true)
[[ -n "$ADMIN_USER" && -n "$ADMIN_PW" ]] \
  || die "could not read secret 'keycloak-bootstrap' in namespace '$NAMESPACE'"

# Escape single quotes so passwords with quotes survive the remote sh -c.
esc() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }
AU=$(esc "$ADMIN_USER"); AP=$(esc "$ADMIN_PW")
LOGIN="$KCADM config credentials --server $KC_LOCAL --realm master --user '$AU' --password '$AP' >/dev/null"

# ── 3. Look up the client's internal id ─────────────────────────────────────
echo "==> Looking up client '$CLIENT_ID' in realm '$REALM'..."
CID=$(kubectl -n "$NAMESPACE" exec deploy/keycloak -c keycloak -- sh -c "
  $LOGIN
  $KCADM get clients -r '$REALM' -q clientId='$CLIENT_ID' --fields id --format csv --noquotes
" 2>/dev/null | tr -d '\r' | head -n1)
[[ -n "$CID" ]] || die "client '$CLIENT_ID' not found in realm '$REALM' (has terraform apply finished?)"
echo "    client id: $CID"

# ── 4. Apply web origins + redirect URIs ────────────────────────────────────
WEB_ORIGINS="[\"$SHOP\",\"$API\"]"
REDIRECTS="[\"$SHOP/*\"]"
echo "==> Setting webOrigins=$WEB_ORIGINS"
kubectl -n "$NAMESPACE" exec deploy/keycloak -c keycloak -- sh -c "
  $LOGIN
  $KCADM update clients/$CID -r '$REALM' \
    -s 'webOrigins=$WEB_ORIGINS' \
    -s 'redirectUris=$REDIRECTS'
" >/dev/null
echo "    applied."

# ── 5. Verify the CORS preflight actually passes ────────────────────────────
# Retried: when run from `terraform apply` the ingress LoadBalancer may still be
# warming up, which would otherwise fail the apply spuriously.
echo "==> Verifying CORS preflight from $SHOP ..."
ORIGIN_HDR=""
for attempt in 1 2 3 4 5; do
  ORIGIN_HDR=$(curl -sk -X OPTIONS \
    "$AUTH/keycloak/realms/$REALM/protocol/openid-connect/token" \
    -H "Origin: $SHOP" -H "Access-Control-Request-Method: POST" \
    -D- -o /dev/null --max-time 20 \
    | tr -d '\r' | grep -i '^access-control-allow-origin:' || true)
  [[ "$ORIGIN_HDR" == *"$SHOP"* ]] && break
  [[ $attempt -lt 5 ]] && { echo "    attempt $attempt: not ready, retrying in 10s..."; sleep 10; }
done

if [[ "$ORIGIN_HDR" == *"$SHOP"* ]]; then
  echo "    OK  $ORIGIN_HDR"
  echo
  echo "CORS fixed. The Login button will now reach Keycloak."
  echo "NOTE: the 'test' user is created by seed.py (§4). Until the seed has run,"
  echo "      the login page appears but credentials are rejected with"
  echo "      'invalid_grant' — that is expected, not a fault."
else
  echo "    got: ${ORIGIN_HDR:-<no access-control-allow-origin header>}" >&2
  die "preflight did not echo the shop origin back. Check that $AUTH is reachable
       and that you accepted its self-signed certificate (§2b)."
fi
