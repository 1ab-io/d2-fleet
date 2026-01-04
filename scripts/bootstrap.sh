#!/bin/sh

set -eu

retry() {
  max=5
  retry=0
  while ! "$@"; do
    retry=$((retry + 1))
    if [ $retry -ge $max ]; then
      echo "Failed to apply manifests after $max attempts"
      exit 1
    fi
    echo "Attempt $retry/$max, waiting 10 seconds..."
    sleep 10
  done
}

# BRANCH="${BRANCH:-main}"
# BASE_URL="https://raw.githubusercontent.com/1ab-io/d2-infra/refs/heads/$BRANCH/manifests"

KUBERNETES_SERVICE_HOST="$CLUSTER_NAME-control-plane"
KUBERNETES_SERVICE_PORT=6443

GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}"
IPV4_ADDRESS="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$KUBERNETES_SERVICE_HOST")"

# kubectl cluster-info
current_context="$(kubectl config current-context)"
if [ "$current_context" != "kind-$CLUSTER_NAME" ]; then
  echo >&2 "Invalid context: $current_context, expected: kind-$CLUSTER_NAME"
  exit 1
fi

tmp_dir="${TMPDIR:-${TMP:-/tmp}}"
base_dir="$tmp_dir/d2-fleet-$ENVIRONMENT"

helm_install() {
  name="$1"
  shift
  tag="$1"
  shift
  dir="$base_dir/$name-$tag"
  if ! [ -d "$dir" ]; then
    mkdir --parent "$dir"
  fi
  url="oci://ghcr.io/1ab-io/d2-infra/$name:$tag"
  flux pull artifact "$url" --output="$dir"

  chart_name="$(yq -r .metadata.name "$dir/controllers/base/release.yaml")"
  namespace="$(yq -r .namespace "$dir/controllers/base/kustomization.yaml")"
  release_name="$(yq -r .spec.releaseName "$dir/controllers/base/release.yaml")"
  repo_name="$(yq -r .metadata.name "$dir/controllers/base/repository.yaml")"
  repo_url="$(yq -r .spec.url "$dir/controllers/base/repository.yaml")"
  # controllers="$dir/controllers/$ENVIRONMENT"
  configs="$dir/configs/$ENVIRONMENT"
  namespace_file="$dir/controllers/base/namespace.yaml"

  if [ -f "$namespace_file" ]; then
    kubectl apply --filename="$namespace_file"
  fi

  values="$dir/values.yaml"
  yq .spec.values "$dir/controllers/base/release.yaml" >"$values"

  case "$repo_url" in
  oci://*)
    # chart="$repo_url/$chart_name"
    chart="$repo_url"
    chart_version="$(yq -r .spec.ref.tag "$dir/controllers/base/repository.yaml")"
    ;;
  *)
    helm repo add "$repo_name" "$repo_url" --force-update >/dev/null
    chart="$repo_name/$chart_name"
    chart_version="$(yq -r .spec.chart.spec.version "$dir/controllers/base/release.yaml")"
    ;;
  esac

  if [ "$chart_version" = null ]; then
    echo >&2 "Unknown chart version for $name"
    chart_version=
  fi
  if [ -n "$chart_version" ]; then
    set -- "$@" --version="$chart_version"
  fi
  # retry helm upgrade --install
  if ! helm status --namespace="$namespace" "$release_name" >/dev/null 2>&1 &&
    ! helm get metadata --namespace="$namespace" "$release_name" >/dev/null 2>&1; then
    echo >&2 "Installing Helm chart $namespace/$release_name"
    retry helm install --namespace="$namespace" "$release_name" "$chart" --create-namespace --values="$values" "$@"
  fi
  if [ "$name" = cilium ]; then
    kubectl wait crd/ciliumloadbalancerippools.cilium.io --for=create --timeout=5m
  fi
  # kubectl apply --kustomize="$controllers"
  if [ -d "$configs" ]; then
    # TODO: ignore namespace (4 keys)
    if [ "$(yq 'keys | length' "$configs/kustomization.yaml")" -eq 3 ] &&
      [ "$(yq -r '.resources | length' "$configs/kustomization.yaml")" -eq 0 ]; then
      echo >&2 "No resources to apply: $configs/kustomization.yaml"
      return
    fi
    echo >&2 "Applying kustomization: $configs"
    retry kubectl apply --kustomize="$configs"
    # kubectl kustomize "$configs" | kubectl apply --filename=- --wait=false
  fi
}

set -x

# kubectl taint node "$CLUSTER_NAME-control-plane" node.kubernetes.io/not-ready:NoSchedule-

# echo >&2 "Applying CRDs"
kubectl apply --filename=https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.crds.yaml
kubectl apply --filename=https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/experimental-install.yaml
kubectl apply --filename=https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/refs/heads/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml

# kubectl apply --filename="$BASE_URL/cert-manager.yaml" || true
# --force-conflicts=true --server-side=true --wait=false

set +x

helm_install cilium latest \
  --set=k8sServiceHost="$KUBERNETES_SERVICE_HOST" \
  --set=k8sServicePort="$KUBERNETES_SERVICE_PORT"

helm_install cert-manager latest \
  --set=crds.enabled=false # --skip-crds
# --set=tolerations[0].key=node.kubernetes.io/network-unavailable \
# --set=tolerations[1].key=node.kubernetes.io/not-ready \
# --set=tolerations[2].key=node.kubernetes.io/unreachable \

# curl -LSfs "$BASE_URL/cilium.yaml" |
#   sed -e 's/"localhost"/"kind-control-plane"/g' -e 's/"7445"/"6443"/g' \
#     >/tmp/cilium.yaml
# if ! [ -s /tmp/cilium.yaml ]; then
#   echo >&2 "Failed to download or modify Cilium manifest: ${BASE_URL}/cilium.yaml"
#   exit 1
# fi

# TODO: wait for cert-manager
# failed calling webhook "webhook.cert-manager.io":
# failed to call webhook: (...) connect: operation not permitted

# kubectl --namespace=cert-manager wait pod -l app=cert-manager,webhook --for=condition=ready --timeout=5m
# kubectl apply --filename=/tmp/cilium.yaml

# retry kubectl apply --filename=/tmp/cilium.yaml
# --filename=$BASE_URL/flux-operator.yaml
# --filename=clusters/$ENVIRONMENT/flux-system/flux-instance.yaml"

# kubectl apply --filename=$BASE_URL/cilium.config.yaml
HOSTNAME_CP1="$CLUSTER_NAME-control-plane"
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
echo >&2 "Applying cilium load balancer IP pool ($HOSTNAME_CP1: $IPV4_ADDRESS)"
kubectl apply --filename="/tmp/cilium-lb-ip-pool-$HOSTNAME_CP1.yaml"

# kubectl apply --filename="$BASE_URL/cert-manager.config.yaml"
# retry kubectl apply --filename=$BASE_URL/cert-manager.config.yaml

# helm uninstall flux-operator --namespace flux-system || true
# if ! helm status --namespace=flux-system flux-operator; then
#   helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
#     --create-namespace \
#     --namespace=flux-system \
#     --set multitenancy.enabled=true \
#     --wait # || true
# fi
# --set tolerations[0].key=node.kubernetes.io/network-unavailable
# --set tolerations[1].key=node.kubernetes.io/not-ready
helm_install flux-operator latest

# Fake b2-runtime-env secret in staging and production
if [ "$ENVIRONMENT" = "staging" ] || [ "$ENVIRONMENT" = "production" ]; then
  if ! kubectl get secret --namespace=flux-system b2-runtime-env >/dev/null; then
    echo >&2 "Creating fake flux-system/b2-runtime-env secret"
    kubectl create secret generic --namespace=flux-system b2-runtime-env \
      --from-literal=B2_APPLICATION_KEY="application_key" \
      --from-literal=B2_APPLICATION_KEY_ID="application_key_id" \
      --from-literal=B2_BUCKET_NAME="bucket_name" \
      --from-literal=B2_ENDPOINT="localhost" \
      --from-literal=B2_REGION="region"
  fi
fi

# if kubectl --namespace=flux-system get configmap flux-runtime-env >/dev/null; then
#   kubectl --namespace=flux-system delete configmap flux-runtime-env
# fi
if ! kubectl get configmap --namespace=flux-system flux-runtime-env >/dev/null; then
  echo >&2 "Creating flux-system/flux-runtime-env configmap"
  kubectl create configmap --namespace=flux-system flux-runtime-env \
    --from-literal=BASE_DOMAIN="$IPV4_ADDRESS.nip.io" \
    --from-literal=CLUSTER_DOMAIN=cluster.local \
    --from-literal=CLUSTER_NAME="$CLUSTER_NAME" \
    --from-literal=GROUP_NAME="1ab-io" \
    --from-literal=HOSTNAME_CP1="$HOSTNAME_CP1" \
    --from-literal=IPV4_ADDRESS="$IPV4_ADDRESS" \
    --from-literal=WHITELIST_SOURCE_RANGE="127.0.0.1/32,172.18.0.1/32" # 10.5.0.1/32
fi

if ! kubectl get configmap --namespace=flux-system flux-runtime-info >/dev/null; then
  echo >&2 "Creating flux-system/flux-runtime-info configmap"
  kubectl create configmap --namespace=flux-system flux-runtime-info \
    --from-literal=CCM="" \
    --from-literal=CNI="cilium" \
    --from-literal=KUBERNETES_SERVICE_HOST="$KUBERNETES_SERVICE_HOST" \
    --from-literal=KUBERNETES_SERVICE_PORT="$KUBERNETES_SERVICE_PORT"
fi

if ! kubectl get secret --namespace=flux-system ghcr-auth >/dev/null; then
  echo >&2 "Creating flux-system/ghcr-auth secret"
  kubectl create secret docker-registry --namespace=flux-system ghcr-auth \
    --docker-server=ghcr.io \
    --docker-username=flux \
    --docker-password="$GITHUB_TOKEN" # || true
fi

set -x

# cat clusters/$ENVIRONMENT/flux-system/flux-instance.yaml \
#   | CLUSTER_DOMAIN=cluster.local envsubst \
#   | kubectl apply --filename=-
kubectl apply --filename="clusters/$ENVIRONMENT/flux-system/flux-instance.yaml"

# # echo >&2 "Waiting for flux-system/flux-runtime-info configmap"
# kubectl wait configmap/flux-runtime-info --namespace=flux-system --for=create --timeout=5m
# # echo >&2 "Patching flux-system/flux-runtime-info configmap"
# kubectl patch configmap/flux-runtime-info --namespace=flux-system --type=merge \
#   --patch='{
#   "metadata": {
#     "annotations": {
#       "fluxcd.controlplane.io/reconcile": "disabled"
#     }
#   },
#   "data": {
#     "CCM": "",
#     "CNI": "cilium",
#     "KUBERNETES_SERVICE_HOST": "'"$KUBERNETES_SERVICE_HOST"'",
#     "KUBERNETES_SERVICE_PORT": "'"$KUBERNETES_SERVICE_PORT"'"
#   }
# }'

# kubectl wait --namespace=flux-system deployment/flux-operator --for=condition=available --timeout=5m
# kubectl wait crd/helmreleases.helm.toolkit.fluxcd.io --for=create --timeout=5m
kubectl wait --namespace=flux-system fluxinstance/flux --for=condition=ready --timeout=5m
# kubectl wait --namespace=kube-system helmrelease/cilium --for=create --timeout=5m

# echo >&2 "Waiting for external-secrets"
kubectl wait namespace/external-secrets --for=create --timeout=5m
kubectl wait --namespace=external-secrets kustomization/external-secrets-controllers --for=create --timeout=5m
kubectl wait --namespace=external-secrets kustomization/external-secrets-controllers --for=condition=ready --timeout=10m
kubectl wait --namespace=external-secrets kustomization/external-secrets-configs --for=condition=ready --timeout=5m

# echo >&2 "Waiting for monitoring"
kubectl wait namespace/monitoring --for=create --timeout=5m
kubectl wait --namespace=monitoring kustomization/monitoring-controllers --for=create --timeout=5m
kubectl wait --namespace=monitoring kustomization/monitoring-controllers --for=condition=ready --timeout=10m
kubectl wait --namespace=monitoring kustomization/monitoring-configs --for=condition=ready --timeout=5m

# echo >&2 "Waiting for ingress-nginx"
kubectl wait namespace/ingress-nginx --for=create --timeout=5m
kubectl wait --namespace=ingress-nginx kustomization/ingress-nginx-controllers --for=condition=ready --timeout=5m

# echo >&2 "Waiting for backend"
kubectl wait namespace/backend --for=create --timeout=1m
kubectl wait --namespace=backend kustomization/backend --for=create --timeout=1m
kubectl wait --namespace=backend kustomization/backend --for=condition=ready --timeout=1m

# echo >&2 "Waiting for frontend"
kubectl wait namespace/frontend --for=create --timeout=1m
kubectl wait --namespace=frontend kustomization/frontend --for=create --timeout=1m
kubectl wait --namespace=frontend kustomization/frontend --for=condition=ready --timeout=1m

curl -k "https://podinfo.$CLUSTER_NAME.$IPV4_ADDRESS.nip.io" # /version
