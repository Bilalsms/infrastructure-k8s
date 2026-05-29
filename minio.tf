locals {
  minio_annotations = yamlencode(merge(local.base_misarch_annotations, local.minio_specific_annotations))
  minio_labels      = yamlencode(merge(local.base_misarch_labels, local.minio_specific_labels))
}

resource "helm_release" "minio" {
  name       = "minio"
  repository = "https://charts.min.io/"
  chart      = "minio"
  namespace  = local.namespace

  values = [
    <<-EOF
    fullnameOverride: "${local.minio_service_name}"
    mode: "standalone"
    rootUser: "admin"
    rootPassword: "${random_password.minio_admin_password.result}"
    persistence:
      enabled: true
    resources:
      requests:
        memory: "512Mi"
        cpu: "100m"
      limits:
        memory: "1Gi"
        cpu: "1000m"
    podAnnotations:
      ${replace(local.minio_annotations, "/\n/", "\n  ")}
    EOF
  ]
}
