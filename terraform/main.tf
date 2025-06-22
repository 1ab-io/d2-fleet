terraform {
  required_version = ">= 1.7"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12"
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

  // Configure the Flux components and kustomize patches.
  values = [
    file("${path.module}/values/instance.yaml")
  ]

  // Configure the Flux distribution.
  set {
    name  = "instance.distribution.version"
    value = var.flux_version
  }
  set {
    name  = "instance.distribution.registry"
    value = var.flux_registry
  }
  set {
    name  = "instance.distribution.artifact"
    value = "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:latest"
  }

  // Configure Flux sync from GitHub Container Registry.
  set {
    name  = "instance.sync.kind"
    value = "OCIRepository"
  }
  set {
    name  = "instance.sync.url"
    value = var.oci_url
  }
  set {
    name  = "instance.sync.path"
    value = var.oci_path
  }
  set {
    name  = "instance.sync.ref"
    value = var.oci_tag
  }
  set {
    name  = "instance.sync.pullSecret"
    value = "ghcr-auth"
  }
}
