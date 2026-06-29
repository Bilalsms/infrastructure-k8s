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
    # Upstream `misarch/media/src/main.rs` hardcodes credentials
    # Proper long-term fix: fork media to read MINIO_USER / MINIO_PASSWORD
    # from env vars (analogous to the inventory pubSubName custom image).
    rootPassword: "password"
    persistence:
      enabled: true
      size: "5Gi"
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
