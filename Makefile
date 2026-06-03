# End-to-end local Apache Druid sandbox on kind.
#
# Bring-up order:
#   kind cluster (+ local registry) -> druid-operator -> garage -> postgres -> druid
#
# Quick start:
#   make up          # full end-to-end bring-up
#   make garage-init # initialize garage (layout + bucket + key) before ingesting
#   make status      # show pods across the sandbox namespaces
#   make down        # delete the kind cluster
#
# Individual steps: make cluster | operator | garage | postgres | druid

SHELL := /bin/bash

CLUSTER_NAME ?= mykindk8s
OPERATOR_NS  ?= druid-operator-system
GARAGE_NS    ?= garage
DRUID_NS     ?= druid
POSTGRES_NS  ?= default
DRUID_DB     ?= druid

# Must match charts/druid/values.yaml deepStorage.s3.{accessKey,secretKey}.
S3_ACCESS_KEY ?= GK2e8295da0aa89eb42f531c44
S3_SECRET_KEY ?= 9d4ce5f41d3f249341cdfe914d377e74d76a99c8ab672b146cb572daab68ce7d

# druid-operator image. The public datainfrahq image is amd64-only, so on arm64
# (e.g. Apple Silicon) the operator is built from source and pushed to the local
# registry instead. Building uses `docker build` (Go is compiled inside the
# image's builder stage) — only Docker + git are needed, not a local Go toolchain.
OPERATOR_REPO      ?= https://github.com/datainfrahq/druid-operator
OPERATOR_VERSION   ?= v1.3.0
OPERATOR_SRC       ?= .build/druid-operator
OPERATOR_LOCAL_IMG ?= localhost:5001/druid-operator
OPERATOR_LOCAL_TAG ?= $(OPERATOR_VERSION)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

.PHONY: up
up: cluster operator garage postgres druid ## Full end-to-end bring-up
	@echo ""
	@echo "Deployed: operator + garage + postgres + druid."
	@echo "Next:"
	@echo "  make garage-init   # required before ingestion (creates layout/bucket/key)"
	@echo "  make status        # watch pods come up"

.PHONY: cluster
cluster: ## Create the kind cluster (1 control-plane + 2 workers) and local registry
	@if kind get clusters 2>/dev/null | grep -qx $(CLUSTER_NAME); then \
	  echo "cluster '$(CLUSTER_NAME)' already exists, skipping"; \
	else \
	  mkdir -p data && ./kind-registry.sh; \
	fi

.PHONY: operator
operator: ## Deploy the druid-operator (public image on amd64; build+push locally on arm64)
	@arch="$$(uname -m)"; \
	if [ "$$arch" = "arm64" ] || [ "$$arch" = "aarch64" ]; then \
	  echo ">> $$arch: public datainfrahq image is amd64-only — building from source"; \
	  $(MAKE) operator-image-local; \
	  helm upgrade --install druid-operator charts/druid-operator \
	    -n $(OPERATOR_NS) --create-namespace \
	    --set image.repository=$(OPERATOR_LOCAL_IMG) --set image.tag=$(OPERATOR_LOCAL_TAG); \
	else \
	  echo ">> $$arch: using public image datainfrahq/druid-operator"; \
	  helm upgrade --install druid-operator charts/druid-operator \
	    -n $(OPERATOR_NS) --create-namespace; \
	fi
	kubectl -n $(OPERATOR_NS) wait --for=condition=Available deploy --all --timeout=300s || true

.PHONY: operator-image-local
operator-image-local: ## Clone druid-operator source and build+push a host-arch image to the local registry
	@if [ ! -d "$(OPERATOR_SRC)/.git" ]; then \
	  echo ">> cloning $(OPERATOR_REPO) @ $(OPERATOR_VERSION) into $(OPERATOR_SRC)"; \
	  git clone --depth 1 --branch $(OPERATOR_VERSION) $(OPERATOR_REPO) $(OPERATOR_SRC); \
	fi
	docker build -t $(OPERATOR_LOCAL_IMG):$(OPERATOR_LOCAL_TAG) $(OPERATOR_SRC)
	docker push $(OPERATOR_LOCAL_IMG):$(OPERATOR_LOCAL_TAG)

.PHONY: garage
garage: ## Deploy garage (S3-compatible deep storage)
	helm upgrade --install garage charts/garage -n $(GARAGE_NS) --create-namespace
	kubectl -n $(GARAGE_NS) rollout status statefulset/garage --timeout=180s

.PHONY: postgres
postgres: ## Deploy postgres (metadata store) and create the druid database
	helm upgrade --install postgres charts/postgresql -n $(POSTGRES_NS) --set auth.database=$(DRUID_DB)
	kubectl -n $(POSTGRES_NS) rollout status deploy/postgres --timeout=180s

.PHONY: druid
druid: ## Deploy the Druid cluster CR (reconciled by the operator)
	helm upgrade --install druid charts/druid -n $(DRUID_NS) --create-namespace
	@echo "Druid CR applied. Watch: kubectl get pods -n $(DRUID_NS) -w"

.PHONY: garage-init
garage-init: ## Initialize garage: layout + create the druid bucket and access key (garage v2.x; adjust if your version differs)
	@set -e; \
	NODE_ID=$$(kubectl exec -n $(GARAGE_NS) garage-0 -- /garage node id -q | cut -d@ -f1); \
	echo "garage node: $$NODE_ID"; \
	kubectl exec -n $(GARAGE_NS) garage-0 -- /garage layout assign -z dc1 -c 5G $$NODE_ID; \
	kubectl exec -n $(GARAGE_NS) garage-0 -- /garage layout apply --version 1; \
	kubectl exec -n $(GARAGE_NS) garage-0 -- /garage bucket create $(DRUID_DB) || true; \
	kubectl exec -n $(GARAGE_NS) garage-0 -- /garage key import --yes -n druid-key $(S3_ACCESS_KEY) $(S3_SECRET_KEY) || true; \
	kubectl exec -n $(GARAGE_NS) garage-0 -- /garage bucket allow --read --write --owner $(DRUID_DB) --key $(S3_ACCESS_KEY)

.PHONY: status
status: ## Show pods across the sandbox namespaces
	-kubectl get pods -n $(OPERATOR_NS)
	-kubectl get pods -n $(GARAGE_NS)
	-kubectl get pods -n $(POSTGRES_NS) -l app=postgres
	-kubectl get pods -n $(DRUID_NS)

.PHONY: down
down: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER_NAME)

.PHONY: clean
clean: down ## Delete the kind cluster and remove the local registry container
	-docker rm -f kind-registry
