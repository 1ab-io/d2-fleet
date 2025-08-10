#!/bin/sh

set -eux

# https://kind.sigs.k8s.io/docs/user/local-registry/
# set -o errexit

DOCKER="${DOCKER:-docker}"
if [ "$DOCKER" = podman ]; then
  export KIND_EXPERIMENTAL_PROVIDER="$DOCKER"
fi

# 1. Create registry container unless it already exists
reg_name='kind-registry'
reg_port='5001'
if [ "$($DOCKER inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  $DOCKER run \
    -d --restart=always -p "127.0.0.1:${reg_port}:5000" --network bridge --name "${reg_name}" \
    registry:2
fi

# 2. Create kind cluster with containerd registry config dir enabled
if ! kind get clusters 2>/dev/null | grep '^kind$'; then
  kind create cluster --config=.github/kind.yaml
fi

# 3. Add the registry config to the nodes
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${reg_port}"
for node in $(kind get nodes); do
  $DOCKER exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | $DOCKER exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${reg_name}:5000"]
EOF
done

# 4. Connect the registry to the cluster network if not already connected
if [ "$($DOCKER inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  $DOCKER network connect "kind" "${reg_name}"
fi

# 5. Document the local registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
