#!/bin/sh

# flux-operator build instance --filename=clusters/staging/flux-system/flux-instance.yaml | kubectl diff --server-side --field-manager=flux-operator -f -

set -eux

# https://github.com/controlplaneio-fluxcd/flux-operator/releases
FLUX_OPERATOR_URL="https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v0.24.1/flux-operator_0.24.1_linux_amd64.tar.gz"
FLUX_OPERATOR_MCP_URL="https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v0.24.1/flux-operator-mcp_0.24.1_linux_amd64.tar.gz"

download() {
  name="$1"
  url="$2"
  curl -LSfso "/tmp/${name}.tar.gz" "$url"
  tar -C /tmp -xzf "/tmp/${name}.tar.gz"
  chmod +x "/tmp/${name}"
  sudo mv "/tmp/${name}" "/usr/local/bin/${name}"
  rm -f "/tmp/${name}.tar.gz"
}

download flux-operator "$FLUX_OPERATOR_URL"
download flux-operator-mcp "$FLUX_OPERATOR_MCP_URL"
