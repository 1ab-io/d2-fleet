#!/bin/sh

set -eux

BRANCH="${BRANCH:-main}"
BASE_URL="https://raw.githubusercontent.com/1ab-io/d2-infra/refs/heads/$BRANCH/manifests"

# sh -c 'set -eux; BRANCH=main; apply() { for name in cert-manager cilium cert-manager.config flux-operator; do kubectl apply --filename="https://raw.githubusercontent.com/1ab-io/d2-infra/refs/heads/${BRANCH}/manifests/${name}.yaml" || return $?; done }; retry=0; while ! apply; do retry=$((retry + 1)); if [ $retry -ge 5 ]; then echo "Failed to apply manifests after 5 attempts"; exit 1; fi; sleep 10; done'
# --force-conflicts=true --server-side=true --wait=false

# Ensure CRDs are installed first
kubectl apply --filename="$BASE_URL/cert-manager.yaml"

curl -LSfs "$BASE_URL/cilium.yaml" |
  sed -e 's/"localhost"/"kind-control-plane"/g' -e 's/"7445"/"6443"/g' \
    >/tmp/cilium.yaml

# TODO: wait for cert-manager
# failed calling webhook "webhook.cert-manager.io":
# failed to call webhook: (...) connect: operation not permitted

# kubectl --namespace=cert-manager wait pod -l app=cert-manager,webhook --for=condition=ready --timeout=5m
# kubectl apply --filename=/tmp/cilium.yaml

max=5 retry=0
while ! kubectl apply --filename=/tmp/cilium.yaml; do
  retry=$((retry + 1))
  if [ $retry -ge $max ]; then
    echo "Failed to apply manifests after $max attempts"
    exit 1
  fi
  echo "Attempt $retry/$max, waiting 60 seconds..."
  sleep 60
done
# --filename=$BASE_URL/flux-operator.yaml
# --filename=clusters/$ENVIRONMENT/flux-system/flux-instance.yaml"

# kubectl apply --filename=$BASE_URL/cilium.config.yaml

kubectl apply --filename="$BASE_URL/cert-manager.config.yaml"
# sh -c 'max=5 retry=0; while ! kubectl apply --filename=$BASE_URL/cert-manager.config.yaml && ; do retry=$((retry + 1)); if [ $retry -ge $max ]; then echo "Failed to apply manifests after $max attempts"; exit 1; fi; echo "Attempt $retry/$max, waiting 60 seconds..."; sleep 60; done'

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

for name in gitlab-agent gitlab-runner; do
  if kubectl --namespace=$name get kustomization/$name >/dev/null; then
    kubectl --namespace=$name patch kustomization/$name \
      --type=merge \
      --patch='{"metadata":{"annotations":{"fluxcd.controlplane.io/reconcile":"false"}}}'
  fi
  if kubectl --namespace=$name get helmrelease/$name >/dev/null; then
    kubectl --namespace=$name delete helmrelease/$name
  fi
done

# kubectl --namespace=kube-system wait kustomization/cilium-controllers --for=create --timeout=5m
# kubectl --namespace=kube-system patch kustomization/cilium-controllers \
#   --type=merge \
#   --patch='{"spec":{"suspend":true}}'
#
# kubectl --namespace=kube-system wait helmrelease/cilium --for=create --timeout=5m
# # kubectl --namespace=kube-system annotate kustomization/cilium-controllers \
# #   ustomize.toolkit.fluxcd.io/reconcile"="disabled" \
# #   overwrite
# kubectl --namespace=kube-system patch helmrelease/cilium \
#   --type=merge \
#   --patch='{"spec":{"values":{"k8sServiceHost":"kind-control-plane","k8sServicePort":6443}}}'
#
# # Remove Talos CCM
# kubectl --namespace=kube-system wait helmrelease/talos-ccm --for=create --timeout=5m
# kubectl --namespace=kube-system delete helmrelease/talos-ccm ocirepository/talos-ccm ocirepository/talos-cloud-controller-manager-chart kustomization/talos-ccm-controllers --wait=false
#
# # Wait for monitoring and apps
# kubectl wait namespace/monitoring --for=create --timeout=5m
# kubectl --namespace=monitoring wait kustomization/monitoring-controllers --for=condition=ready --timeout=5m
# kubectl --namespace=monitoring wait kustomization/monitoring-configs --for=condition=ready --timeout=5m
#
# kubectl wait namespace/backend --for=create --timeout=5m
# kubectl --namespace=backend wait kustomization/apps --for=condition=ready --timeout=5m
#
# kubectl wait namespace/frontend --for=create --timeout=5m
# kubectl --namespace=frontend wait kustomization/apps --for=condition=ready --timeout=5m
