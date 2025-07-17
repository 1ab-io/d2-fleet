terraform {
  required_version = ">= 1.7"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0"
    }
  }
}

// Create the  flux-system namespace.
resource "kubernetes_namespace" "flux_system" {
  metadata {
    name = "flux-system"
  }

  lifecycle {
    ignore_changes = [metadata]
  }
}

// Create a Kubernetes image pull secret for GHCR.
resource "kubernetes_secret" "git_auth" {
  depends_on = [kubernetes_namespace.flux_system]

  metadata {
    name      = "ghcr-auth"
    namespace = "flux-system"
  }

  data = {
    ".dockerconfigjson" = jsonencode({
      "auths" : {
        "ghcr.io" : {
          username = "flux"
          password = var.oci_token
          auth     = base64encode(join(":", ["flux", var.oci_token]))
        }
      }
    })
  }

  type = "kubernetes.io/dockerconfigjson"
}

// Install the Flux Operator.
resource "helm_release" "flux_operator" {
  depends_on = [kubernetes_namespace.flux_system]

  name       = "flux-operator"
  namespace  = "flux-system"
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-operator"
  wait       = true

  values = [
    file("${path.module}/values/operator.yaml")
  ]
}

// Configure the Flux instance.
resource "helm_release" "flux_instance" {
  depends_on = [helm_release.flux_operator]

  name       = "flux"
  namespace  = "flux-system"
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-instance"

  // Configure the Flux distribution and sync from GitHub Container Registry.
  values = [
    templatefile("${path.module}/values/instance.yaml", {

      distribution_version  = var.flux_version
      distribution_registry = var.flux_registry
      distribution_artifact = "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:latest"

      sync_kind        = "OCIRepository"
      sync_url         = var.oci_url
      sync_path        = var.oci_path
      sync_ref         = var.oci_tag
      sync_pull_secret = "ghcr-auth"

      cluster_domain = var.cluster_domain
    })
  ]
}
