// Single self-signed ClusterIssuer used by every Ingress

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
