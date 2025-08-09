#!/bin/sh

set -eux

retry() {
  max=5
  retry=0
  while ! "$@"; do
    retry=$((retry + 1))
    if [ $retry -ge $max ]; then
      echo "Failed to apply manifests after $max attempts"
      exit 1
    fi
    echo "Attempt $retry/$max, waiting 60 seconds..."
    sleep 60
  done
}

BRANCH="${BRANCH:-main}"
BASE_URL="https://raw.githubusercontent.com/1ab-io/d2-infra/refs/heads/$BRANCH/manifests"

# kubectl cluster-info
current_context="$(kubectl config current-context)"
if [ "$current_context" != kind-kind ]; then
  echo >&2 "Invalid context: $current_context"
  exit 1
fi

kubectl apply \
  --filename=https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/experimental-install.yaml \
  --filename=https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/refs/heads/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml

kubectl apply --filename="$BASE_URL/cert-manager.yaml" || true
# --force-conflicts=true --server-side=true --wait=false

curl -LSfs "$BASE_URL/cilium.yaml" |
  sed -e 's/"localhost"/"kind-control-plane"/g' -e 's/"7445"/"6443"/g' \
    >/tmp/cilium.yaml

# TODO: wait for cert-manager
# failed calling webhook "webhook.cert-manager.io":
# failed to call webhook: (...) connect: operation not permitted

# kubectl --namespace=cert-manager wait pod -l app=cert-manager,webhook --for=condition=ready --timeout=5m
# kubectl apply --filename=/tmp/cilium.yaml

retry kubectl apply --filename=/tmp/cilium.yaml
# --filename=$BASE_URL/flux-operator.yaml
# --filename=clusters/$ENVIRONMENT/flux-system/flux-instance.yaml"

# kubectl apply --filename=$BASE_URL/cilium.config.yaml
HOSTNAME_CP1=kind-control-plane
cat >/tmp/cilium-lb-ip-pool-$HOSTNAME_CP1.yaml <<EOF
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: $HOSTNAME_CP1
spec:
  blocks:
    - cidr: "$IPV4_ADDRESS/32"
    # - cidr: "::/128"
  disabled: false
  serviceSelector:
    matchLabels:
      app.kubernetes.io/name: ingress-nginx
      node: $HOSTNAME_CP1
EOF
kubectl apply --filename=/tmp/cilium-lb-ip-pool-$HOSTNAME_CP1.yaml

kubectl apply --filename="$BASE_URL/cert-manager.config.yaml"
# retry kubectl apply --filename=$BASE_URL/cert-manager.config.yaml

# helm uninstall flux-operator --namespace flux-system || true
if ! helm status --namespace=flux-system flux-operator; then
  helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
    --create-namespace \
    --namespace=flux-system \
    --set multitenancy.enabled=true \
    --wait # || true
fi
# --set tolerations[0].key=node.kubernetes.io/network-unavailable
# --set tolerations[1].key=node.kubernetes.io/not-ready

# if kubectl --namespace=flux-system get configmap flux-runtime-env >/dev/null; then kubectl --namespace=flux-system delete configmap flux-runtime-env; fi
if ! kubectl --namespace=flux-system get configmap flux-runtime-env >/dev/null; then
  kubectl --namespace=flux-system create configmap flux-runtime-env \
    --from-literal=CLUSTER_DOMAIN=cluster.local \
    --from-literal=CLUSTER_NAME="$CLUSTER_NAME" \
    --from-literal=WHITELIST_SOURCE_RANGE="127.0.0.1/32"
fi

# if kubectl --namespace=flux-system get secret ghcr-auth >/dev/null; then kubectl --namespace=flux-system delete secret ghcr-auth; fi
if ! kubectl --namespace=flux-system get secret ghcr-auth >/dev/null; then
  kubectl --namespace=flux-system create secret docker-registry ghcr-auth \
    --docker-server=ghcr.io \
    --docker-username=flux \
    --docker-password="$GITHUB_TOKEN" # || true
fi

# cat clusters/$ENVIRONMENT/flux-system/flux-instance.yaml \
#   | CLUSTER_DOMAIN=cluster.local envsubst \
#   | kubectl apply --filename=-
kubectl apply --filename="clusters/$ENVIRONMENT/flux-system/flux-instance.yaml"

kubectl --namespace=flux-system wait fluxinstance/flux --for=condition=ready --timeout=5m

# kubectl --namespace=kube-system wait kustomization/cilium-controllers --for=create --timeout=5m
# kubectl --namespace=kube-system patch kustomization/cilium-controllers \
#   --type=merge \
#   --patch='{"spec":{"suspend":true}}'

kubectl --namespace=kube-system wait helmrelease/cilium --for=create --timeout=5m
# kubectl --namespace=kube-system annotate kustomization/cilium-controllers \
#   ustomize.toolkit.fluxcd.io/reconcile"="disabled" \
#   overwrite
# kubectl --namespace=kube-system patch helmrelease/cilium \
#   --type=merge \
#   --patch='{"spec":{"values":{"k8sServiceHost":"kind-control-plane","k8sServicePort":6443}}}'

# # Remove Talos CCM
# kubectl --namespace=kube-system wait helmrelease/talos-ccm --for=create --timeout=5m
# kubectl --namespace=kube-system delete helmrelease/talos-ccm ocirepository/talos-ccm ocirepository/talos-cloud-controller-manager-chart kustomization/talos-ccm-controllers --wait=false
#
# # Wait for monitoring and apps
# kubectl wait namespace/monitoring --for=create --timeout=5m
# kubectl --namespace=monitoring wait kustomization/monitoring-controllers --for=condition=ready --timeout=5m
# kubectl --namespace=monitoring wait kustomization/monitoring-configs --for=condition=ready --timeout=5m

kubectl wait namespace/ingress-nginx --for=create --timeout=5m
kubectl --namespace=ingress-nginx wait kustomization/ingress-nginx-controllers --for=condition=ready --timeout=5m

# kubectl wait namespace/backend --for=create --timeout=5m
# kubectl --namespace=backend wait kustomization/apps --for=condition=ready --timeout=5m
#
# kubectl wait namespace/frontend --for=create --timeout=5m
# kubectl --namespace=frontend wait kustomization/apps --for=condition=ready --timeout=5m
