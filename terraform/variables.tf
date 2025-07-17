variable "oci_token" {
  description = "GitHub PAT"
  sensitive   = true
  type        = string
  nullable    = false
}

variable "oci_url" {
  description = "OCI repository URL"
  type        = string
  default     = "oci://ghcr.io/1ab-io/d2-fleet"
}

variable "oci_path" {
  description = "Path to the cluster manifests in the OCI artifact"
  type        = string
  nullable    = false
}

variable "oci_tag" {
  description = "OCI artifact tag"
  type        = string
  nullable    = false
}

variable "flux_version" {
  description = "Flux version semver range"
  type        = string
  default     = "2.x"
}

variable "flux_registry" {
  description = "Flux distribution registry"
  type        = string
  default     = "ghcr.io/fluxcd"
}

variable "cluster_domain" {
  description = "Cluster domain"
  type        = string
  default     = "cluster.local"
}
