# Makefile for Vault K8s Unsealer

# Variables
NAMESPACE ?= vault
IMAGE_REGISTRY ?= your-registry
IMAGE_NAME ?= vault-k8s-unsealer
IMAGE_TAG ?= latest
IMAGE_FULL = $(IMAGE_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: help
help: ## Show this help
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-25s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Docker operations
.PHONY: docker-build
docker-build: ## Build Docker image
	docker build -f Dockerfile.k8s -t $(IMAGE_FULL) .
	@echo "Built: $(IMAGE_FULL)"

.PHONY: docker-push
docker-push: ## Push image to registry
	docker push $(IMAGE_FULL)
	@echo "Pushed: $(IMAGE_FULL)"

.PHONY: docker-test
docker-test: ## Test image locally
	docker run --rm $(IMAGE_FULL) --help

# Kubernetes operations
.PHONY: k8s-create-namespace
k8s-create-namespace: ## Create namespace
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

.PHONY: k8s-create-secret
k8s-create-secret: ## Create secret (interactive)
	@echo "Enter unseal keys:"
	@read -p "Key 1: " KEY1; \
	read -p "Key 2: " KEY2; \
	read -p "Key 3: " KEY3; \
	kubectl create secret generic vault-unseal-keys \
		--from-literal=VAULT_UNSEAL_KEY_1=$$KEY1 \
		--from-literal=VAULT_UNSEAL_KEY_2=$$KEY2 \
		--from-literal=VAULT_UNSEAL_KEY_3=$$KEY3 \
		-n $(NAMESPACE) \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: k8s-update-manifest
k8s-update-manifest: ## Update manifest with current image
	sed -i.bak 's|your-registry/vault-k8s-unsealer:latest|$(IMAGE_FULL)|g' vault-unsealer-k8s.yaml
	@echo "Updated manifest to use: $(IMAGE_FULL)"

.PHONY: k8s-deploy
k8s-deploy: k8s-create-namespace k8s-update-manifest ## Deploy to K8s
	kubectl apply -f vault-unsealer-k8s.yaml
	@echo "Deployed to namespace: $(NAMESPACE)"

.PHONY: k8s-deploy-cronjob-only
k8s-deploy-cronjob-only: ## Deploy only CronJob
	kubectl apply -f vault-unsealer-k8s.yaml
	kubectl delete deployment vault-unsealer-watcher -n $(NAMESPACE) --ignore-not-found=true

.PHONY: k8s-deploy-watcher-only
k8s-deploy-watcher-only: ## Deploy only Watcher
	kubectl apply -f vault-unsealer-k8s.yaml
	kubectl delete cronjob vault-unsealer -n $(NAMESPACE) --ignore-not-found=true

.PHONY: k8s-delete
k8s-delete: ## Delete all resources
	kubectl delete -f vault-unsealer-k8s.yaml --ignore-not-found=true

# Operations
.PHONY: status
status: ## Show status
	@echo "=== Vault Pods ==="
	kubectl get pods -n $(NAMESPACE) -l app=vault
	@echo ""
	@echo "=== Unsealer Resources ==="
	kubectl get all -n $(NAMESPACE) -l app=vault-unsealer
	@echo ""
	@echo "=== Recent Jobs ==="
	kubectl get jobs -n $(NAMESPACE) -l component=job --sort-by=.metadata.creationTimestamp | tail -5

.PHONY: logs-watcher
logs-watcher: ## View watcher logs
	kubectl logs -f -n $(NAMESPACE) -l component=watcher

.PHONY: logs-cronjob
logs-cronjob: ## View latest CronJob logs
	@JOB=$$(kubectl get jobs -n $(NAMESPACE) -l component=job --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null); \
	if [ -n "$$JOB" ]; then \
		kubectl logs -f -n $(NAMESPACE) job/$$JOB; \
	else \
		echo "No CronJob runs found"; \
	fi

.PHONY: unseal-now
unseal-now: ## Run manual unseal
	kubectl create job vault-unseal-$$(date +%s) \
		--from=cronjob/vault-unsealer \
		-n $(NAMESPACE)
	@echo "Created manual unseal job"

.PHONY: restart-watcher
restart-watcher: ## Restart watcher deployment
	kubectl rollout restart deployment/vault-unsealer-watcher -n $(NAMESPACE)
	kubectl rollout status deployment/vault-unsealer-watcher -n $(NAMESPACE)

.PHONY: health-check
health-check: ## Run health check
	kubectl run vault-health-check-$$(date +%s) \
		--rm -it \
		--image=$(IMAGE_FULL) \
		--restart=Never \
		--env="VAULT_NAMESPACE=$(NAMESPACE)" \
		-n $(NAMESPACE) \
		-- --health-check --json || true

# Development
.PHONY: dev-install
dev-install: ## Install Python dependencies
	pip install -r requirements.txt

.PHONY: dev-test-local
dev-test-local: ## Test locally
	@echo "Testing vault-k8s-unsealer.py..."
	./vault-k8s-unsealer.py --help

.PHONY: dev-run-local
dev-run-local: ## Run locally against cluster
	@echo "Make sure you have KUBECONFIG and VAULT_UNSEAL_KEY_* set"
	./vault-k8s-unsealer.py --namespace $(NAMESPACE) --verbose

# All-in-one commands
.PHONY: install
install: docker-build docker-push k8s-deploy ## Build, push, and deploy

.PHONY: update
update: docker-build docker-push k8s-update-manifest ## Update existing deployment
	kubectl rollout restart deployment/vault-unsealer-watcher -n $(NAMESPACE) || true

.PHONY: clean
clean: ## Clean build artifacts
	rm -f vault-unsealer-k8s.yaml.bak
	find . -type f -name '*.pyc' -delete
	find . -type d -name '__pycache__' -delete

# Monitoring
.PHONY: watch-pods
watch-pods: ## Watch Vault pods
	watch -n 5 kubectl get pods -n $(NAMESPACE) -l app=vault

.PHONY: watch-unsealer
watch-unsealer: ## Watch unsealer resources
	watch -n 5 kubectl get all -n $(NAMESPACE) -l app=vault-unsealer

.PHONY: events
events: ## Show recent events
	kubectl get events -n $(NAMESPACE) --sort-by='.lastTimestamp' | tail -20

# Troubleshooting
.PHONY: describe-cronjob
describe-cronjob: ## Describe CronJob
	kubectl describe cronjob vault-unsealer -n $(NAMESPACE)

.PHONY: describe-watcher
describe-watcher: ## Describe watcher deployment
	kubectl describe deployment vault-unsealer-watcher -n $(NAMESPACE)

.PHONY: check-rbac
check-rbac: ## Check RBAC permissions
	kubectl auth can-i list pods --as=system:serviceaccount:$(NAMESPACE):vault-unsealer -n $(NAMESPACE)
	kubectl auth can-i get pods --as=system:serviceaccount:$(NAMESPACE):vault-unsealer -n $(NAMESPACE)

.PHONY: get-secret
get-secret: ## View secret (base64 encoded)
	kubectl get secret vault-unseal-keys -n $(NAMESPACE) -o yaml

.PHONY: shell
shell: ## Open shell in debug pod
	kubectl run -it --rm debug \
		--image=busybox \
		--restart=Never \
		-n $(NAMESPACE) \
		-- sh
