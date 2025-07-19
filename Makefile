# Makefile for deploying the Flux Operator

# Prerequisites:
# - Kubectl
# - Helm
# - Flux CLI

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

REPOSITORY ?= https://github.com/controlplaneio-fluxcd/d2-fleet
REGISTRY ?= ghcr.io/controlplaneio-fluxcd/d2-fleet

.PHONY: all
all: push bootstrap-staging

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Cluster

CLUSTER_NAME ?= talos-default
# NOTE: qemu requires sudo -E
PROVISIONER ?= docker

CONTROL_PLANE_COUNT ?= 1
WORKER_COUNT ?= 1
TALOS_VERSION ?= 1.10.4
WAIT ?= true
TIMEOUT ?= 5m

IPV4_ADDRESS ?= 10.5.0.2

cluster-up: ## Creates a Kubernetes KinD cluster and a local registry bind to localhost:5050.
	sh ./scripts/kind.sh

cluster-debug: ## Debug cluster
	# docker logs $(CLUSTER_NAME)-controlplane-1 --follow --since=1m
	kubectl config current-context
	kubectl cluster-info --context kind-kind

cluster-down: ## Shutdown the Kubernetes KinD cluster and the local registry.
	kind delete cluster
	docker stop kind-registry
	docker rm --force kind-registry

talos-up: ## Creates a Kubernetes Talos cluste
	echo "cluster: { network: { cni: { name: none } }, proxy: { disabled: true } }" \
	  >"/tmp/patch.yaml"
	talosctl cluster create --name=$(CLUSTER_NAME) --provisioner=$(PROVISIONER) \
	  --controlplanes=$(CONTROL_PLANE_COUNT) \
	  --workers=$(WORKER_COUNT) \
	  --skip-k8s-node-readiness-check \
	  --talos-version=$(TALOS_VERSION) \
	  --wait=$(WAIT) \
	  --wait-timeout=$(TIMEOUT) \
	  --with-debug \
	  --with-json-logs \
	  --config-patch-control-plane="@/tmp/patch.yaml"
	talosctl config contexts
	kubectl config get-contexts

talos-debug: ## Debug cluster
	# docker logs $(CLUSTER_NAME)-controlplane-1 --follow --since=1m
	# talosctl dashboard --cluster=admin@talos-default --nodes=$(IPV4_ADDRESS)

	talosctl config info
	kubectl config current-context

	talosctl cluster show --name=$(CLUSTER_NAME)

	# kubectl config delete-context admin@$(CLUSTER_NAME)
	# kubectl config rename-context admin@$(CLUSTER_NAME)-1 admin@$(CLUSTER_NAME)

	# talosctl config context $(CLUSTER_NAME)
	talosctl config contexts

	# kubectl config use-context admin@$(CLUSTER_NAME)
	kubectl config get-contexts

	talosctl get members --nodes=$(IPV4_ADDRESS)

	kubectl get nodes -o=wide

talos-down: ## Shutdown the Kubernetes Talos cluster
	talosctl cluster destroy --name=$(CLUSTER_NAME) --provisioner=$(PROVISIONER)
	# talosctl config context ""
	# talosctl config remove $(CLUSTER_NAME)
	# kubectl config delete-context admin@$(CLUSTER_NAME)

>>>>>>> 751673f (fix: single production cluster)
##@ Artifacts

push: ## Push the Kubernetes manifests to Github Container Registry.
	flux push artifact oci://$(REGISTRY):latest \
	  --path=./ \
	  --source=$(REPOSITORY) \
	  --revision="$$(git branch --show-current)@sha1:$$(git rev-parse HEAD)"

##@ Flux

BRANCH ?= main
BASE_URL ?= https://raw.githubusercontent.com/1ab-io/d2-infra/refs/heads/$(BRANCH)/manifests/

bootstrap-staging: ## Deploy Flux Operator on the staging Kubernetes cluster.
	@test $${GITHUB_TOKEN?Environment variable not set}

	# sh -c 'set -eux; BRANCH=main; apply() { for name in cert-manager cilium cert-manager.config flux-operator; do kubectl apply --filename="https://raw.githubusercontent.com/1ab-io/d2-infra/refs/heads/$${BRANCH}/manifests/$${name}.yaml" || return $?; done }; retry=0; while ! apply; do retry=$$((retry + 1)); if [ $$retry -ge 5 ]; then echo "Failed to apply manifests after 5 attempts"; exit 1; fi; sleep 10; done'
	# --force-conflicts=true --server-side=true --wait=false

	# Ensure CRDs are installed first
	kubectl apply --filename=$(BASE_URL)cert-manager.yaml
	# --filename=$(BASE_URL)cert-manager.config.yaml

	curl -LSfs $(BASE_URL)cilium.yaml \
		| sed -e 's/"localhost"/"kind-control-plane"/g' -e 's/"7445"/"6443"/g' \
		>/tmp/cilium.yaml

	# TODO: wait for cert-manager
	# failed calling webhook "webhook.cert-manager.io":
	# failed to call webhook: (...) connect: operation not permitted

	# kubectl --namespace=cert-manager wait pod -l app=cert-manager,webhook --for=condition=ready --timeout=5m
	# kubectl apply --filename=/tmp/cilium.yaml
	
	sh -c 'retry=0; while ! kubectl apply --filename=/tmp/cilium.yaml; do retry=$$((retry + 1)); if [ $$retry -ge 3 ]; then echo "Failed to apply manifests after 5 attempts"; exit 1; fi; echo "Attempt $$retry/5, waiting 60 seconds..."; sleep 60; done'
	# --filename=$(BASE_URL)flux-operator.yaml
	# --filename=clusters/staging/flux-system/flux-instance.yaml"

	# helm uninstall flux-operator --namespace flux-system || true
	helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
	  --namespace flux-system \
	  --create-namespace \
	  --set multitenancy.enabled=true \
	  --wait # || true
	# --set tolerations[0].key=node.kubernetes.io/network-unavailable
	# --set tolerations[1].key=node.kubernetes.io/not-ready

	kubectl --namespace=flux-system create configmap flux-runtime-env \
	  --from-literal=CLUSTER_DOMAIN=cluster.local \
	  --from-literal=CLUSTER_NAME=$(CLUSTER_NAME) # || true

	kubectl --namespace=flux-system create secret docker-registry ghcr-auth \
	  --docker-server=ghcr.io \
	  --docker-username=flux \
	  --docker-password=$$GITHUB_TOKEN # || true

	# cat clusters/staging/flux-system/flux-instance.yaml \
	#   | CLUSTER_DOMAIN=cluster.local envsubst \
	#   | kubectl apply --filename=-
	kubectl apply --filename=clusters/staging/flux-system/flux-instance.yaml

	kubectl --namespace=flux-system wait fluxinstance/flux --for=condition=ready --timeout=5m

	# kubectl --namespace=kube-system wait kustomization/cilium-controllers --for=create --timeout=5m
	# kubectl --namespace=kube-system patch kustomization/cilium-controllers \
	# 	--type=merge \
	# 	--patch='{"spec":{"suspend":true}}'
	#
	# kubectl --namespace=kube-system wait helmrelease/cilium --for=create --timeout=5m
	# # kubectl --namespace=kube-system annotate kustomization/cilium-controllers \
	# # 	"kustomize.toolkit.fluxcd.io/reconcile"="disabled" \
	# # 	--overwrite
	# kubectl --namespace=kube-system patch helmrelease/cilium \
	# 	--type=merge \
	# 	--patch='{"spec":{"values":{"k8sServiceHost":"kind-control-plane","k8sServicePort":6443}}}'
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

	# TODO: curl podinfo.cluster.local

bootstrap-production: ## Deploy Flux Operator on the production Kubernetes cluster.
	@test $${GITHUB_TOKEN?Environment variable not set}

	helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
	  --namespace flux-system \
	  --create-namespace \
	  --set multitenancy.enabled=true \
	  --wait

	kubectl --namespace=flux-system create secret docker-registry ghcr-auth \
	  --docker-server=ghcr.io \
	  --docker-username=flux \
	  --docker-password=$$GITHUB_TOKEN

	kubectl apply --filename=clusters/production/flux-system/flux-instance.yaml

	kubectl --namespace=flux-system wait fluxinstance/flux --for=condition=ready --timeout=5m

bootstrap-update: ## Deploy Flux Operator on the image update automation Kubernetes cluster.
	@test $${GITHUB_TOKEN?Environment variable not set for GHCR}
	@test $${GH_UPDATE_TOKEN?Environment variable not set for GitHub repos}

	helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
	  --namespace flux-system \
	  --create-namespace \
	  --set multitenancy.enabled=true \
	  --wait

	kubectl --namespace=flux-system create secret docker-registry ghcr-auth \
	  --docker-server=ghcr.io \
	  --docker-username=flux \
	  --docker-password=$$GITHUB_TOKEN

	kubectl --namespace=flux-system create secret generic github-auth \
	  --from-literal=username=flux \
	  --from-literal=password=$$GH_UPDATE_TOKEN

	kubectl apply --filename=clusters/update/flux-system/flux-instance.yaml

	kubectl --namespace=flux-system wait fluxinstance/flux --for=condition=ready --timeout=5m

verify-cluster: # Verify cluster reconciliation
	kubectl --namespace=flux-system wait Kustomization/flux-system --for=condition=ready --timeout=5m
	kubectl --namespace=flux-system wait ResourceSet/infra --for=condition=ready --timeout=5m
	kubectl --namespace=flux-system wait ResourceSet/apps --for=condition=ready --timeout=5m
	kubectl --namespace=backend wait Kustomization/apps --for=condition=ready --timeout=5m
	kubectl --namespace=frontend wait Kustomization/apps --for=condition=ready --timeout=5m

debug-cluster: # Debug failure
	kubectl --namespace=flux-system get all
	kubectl --namespace=flux-system logs deploy/flux-operator
	kubectl --namespace=flux-system logs deploy/source-controller
	kubectl --namespace=flux-system logs deploy/kustomize-controller
	kubectl --namespace=flux-system logs deploy/helm-controller
	flux get all --all-namespaces
