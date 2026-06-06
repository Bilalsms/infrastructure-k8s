// ClusterIssuers reused by every Ingress that opts in via cert-manager annotations.
//
// Two issuers:
//   - selfsigned-cluster: zero-DNS default. Browsers will warn once per host then cache.
//                         Good enough for measurement work and the reproduction video.
//   - letsencrypt-prod:   real cert. Only works when the Ingress host actually resolves
//                         to the LB IP from the public internet (HTTP-01 challenge).
//
// Switch an Ingress by changing its `cert-manager.io/cluster-issuer` annotation.

resource "kubectl_manifest" "selfsigned_cluster_issuer" {
  depends_on = [helm_release.cert_manager]
  yaml_body  = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: selfsigned-cluster
    spec:
      selfSigned: {}
  YAML
}

resource "kubectl_manifest" "letsencrypt_prod_cluster_issuer" {
  depends_on = [helm_release.cert_manager, helm_release.ingress_nginx]
  yaml_body  = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: letsencrypt-prod
    spec:
      acme:
        server: https://acme-v02.api.letsencrypt.org/directory
        email: ${var.LETSENCRYPT_EMAIL}
        privateKeySecretRef:
          name: letsencrypt-prod-account-key
        solvers:
          - http01:
              ingress:
                class: nginx
  YAML
}
