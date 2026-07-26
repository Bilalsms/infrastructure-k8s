// Keycloak CORS for the split-origin deployment.
//
// PROBLEM
//   The `frontend` client is defined inside the upstream Keycloak image
//   (`ghcr.io/misarch/keycloak`), whose realm import ships an EMPTY
//   `webOrigins` list. Upstream MiSArch serves the SPA and Keycloak from the
//   same origin, so it never needed one. We run split-origin —
//   SPA on  misarch.<ip>.nip.io , Keycloak on  auth.misarch.<ip>.nip.io  —
//   so every keycloak-js call is cross-origin. With no allowed web origin the
//   browser blocks the CORS preflight and the storefront's Login button does
//   nothing at all: no redirect, no error, no Keycloak page.
//
//   `redirectUris` does not help — redirect URIs and web origins are enforced
//   independently.
//
// WHY A PROVISIONER AND NOT A DECLARATIVE RESOURCE
//   The realm lives inside the container image, so there is no Terraform-managed
//   realm JSON to edit. Managing the client declaratively would mean adopting a
//   Keycloak Terraform provider, which cannot authenticate until Keycloak is
//   running — a provider-configuration cycle inside a single apply. Patching
//   post-apply via the in-pod `kcadm.sh` is the canonical Keycloak management
//   path and is what the project already uses elsewhere (see
//   load-tests/bump-realm.sh).
//
// IDEMPOTENCE / RE-RUN SEMANTICS
//   `triggers_replace` re-runs the patch when either input actually changes:
//     * the ingress IP  — the allowed origins are derived from it;
//     * the Keycloak deployment UID — a new UID means the pod (and therefore the
//       realm import) was recreated, e.g. after `kubectl delete namespace misarch`,
//       which silently resets `webOrigins` back to empty.
//   It deliberately does NOT trigger on every apply.
//
// MANUAL EQUIVALENT
//   ./fix-keycloak-cors.sh [ingress-ip]      (same script, safe to run anytime)

resource "terraform_data" "keycloak_frontend_cors" {
  depends_on = [
    kubernetes_deployment.keycloak,
    helm_release.ingress_nginx,
    google_compute_address.misarch_ingress,
  ]

  triggers_replace = [
    google_compute_address.misarch_ingress.address,
    kubernetes_deployment.keycloak.metadata[0].uid,
  ]

  provisioner "local-exec" {
    command     = "${path.module}/fix-keycloak-cors.sh ${google_compute_address.misarch_ingress.address}"
    interpreter = ["/bin/bash", "-c"]

    environment = {
      NAMESPACE = local.namespace
      REALM     = "Misarch"
      CLIENT_ID = "frontend"
    }
  }
}
