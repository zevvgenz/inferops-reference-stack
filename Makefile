.PHONY: cluster build load argocd install secrets-decrypt secrets-encrypt verify verify-gitops uninstall destroy lint

CLUSTER_NAME := reference-stack
NAMESPACE := default
RELEASE := reference-stack
CHART := charts/reference-stack
IMAGE := reference-stack-app:dev
DECRYPTED_SECRETS := secrets/secrets.dec.yaml
ENCRYPTED_SECRETS := secrets/secrets.enc.yaml
# Pinned, not `stable` (which floats and re-resolves to whatever ArgoCD
# considers current at install time — a repo meant to be reproducible a
# year from now can't depend on that staying the same). To bump: check
# https://github.com/argoproj/argo-cd/releases for the latest tag, update
# this value, re-run `make argocd`, and update the version + reason in
# README's "Upgrading ArgoCD" note.
ARGOCD_VERSION ?= v3.5.0

cluster: ## Create the kind cluster (idempotent: no-op if it already exists)
	@if kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)"; then \
		echo "==> kind cluster '$(CLUSTER_NAME)' already exists, skipping"; \
	else \
		echo "==> creating kind cluster '$(CLUSTER_NAME)'"; \
		kind create cluster --name $(CLUSTER_NAME) --config kind/kind-config.yaml; \
	fi

build: ## Build the app image used by both the Deployment and the migration Job
	@echo "==> building $(IMAGE)"
	docker build -t $(IMAGE) ./app

load: build ## Load the built image into the kind cluster (kind nodes don't share the host's image store)
	@echo "==> loading $(IMAGE) into kind cluster '$(CLUSTER_NAME)'"
	kind load docker-image $(IMAGE) --name $(CLUSTER_NAME)

argocd: ## Install ArgoCD into the cluster (idempotent: kubectl apply is safe to re-run)
	@echo "==> installing ArgoCD $(ARGOCD_VERSION)"
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	# --server-side, not client-side apply: ArgoCD's own CRDs (notably
	# applicationsets.argoproj.io) exceed the 262144-byte limit on the
	# kubectl.kubernetes.io/last-applied-configuration annotation that
	# client-side `kubectl apply` writes, and fail outright. Server-side
	# apply doesn't need that annotation — it tracks field ownership in
	# the API server instead — so it has no such size ceiling.
	kubectl apply -n argocd --server-side --force-conflicts \
		-f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
	@echo "==> waiting for argocd-server to be available"
	kubectl -n argocd rollout status deployment/argocd-server --timeout=180s

secrets-decrypt: ## Decrypt secrets/secrets.enc.yaml into the gitignored secrets/secrets.dec.yaml used by `make install`
	@echo "==> decrypting $(ENCRYPTED_SECRETS)"
	sops -d $(ENCRYPTED_SECRETS) > $(DECRYPTED_SECRETS)

secrets-encrypt: ## Re-encrypt secrets/secrets.dec.yaml back into secrets/secrets.enc.yaml after editing it
	@echo "==> encrypting $(DECRYPTED_SECRETS)"
	# `sops -e -i` on a copy already named *.enc.yaml, not `sops -e ... >`:
	# .sops.yaml's creation_rules path_regex matches against the INPUT
	# file's path, not the output redirect target. `sops -e
	# secrets.dec.yaml > secrets.enc.yaml` silently fails to match any
	# rule (the input is secrets.dec.yaml) and truncates secrets.enc.yaml
	# via the shell redirect before sops even reports the error — this
	# bit us once already. Encrypting in place on a correctly-named copy
	# avoids the mismatch entirely.
	cp $(DECRYPTED_SECRETS) $(ENCRYPTED_SECRETS)
	sops -e -i $(ENCRYPTED_SECRETS)

install: load secrets-decrypt ## helm install/upgrade the chart (depends on build+load so the image actually exists in-cluster)
	@echo "==> installing/upgrading release '$(RELEASE)'"
	# No --wait here, deliberately: the app Deployment's readinessProbe
	# (/readyz) only turns healthy once the post-install migration Job has
	# created the schema, and Helm's --wait blocks on ordinary-resource
	# readiness *before* running post-install hooks — so --wait would
	# deadlock waiting on a Deployment that can't become ready until a hook
	# --wait itself is blocking. See docs/decisions.md "Migration ordering
	# (round 2)". `make verify` is what actually waits for and asserts
	# on completion, via explicit `kubectl wait` / `rollout status`.
	helm upgrade --install $(RELEASE) $(CHART) \
		--namespace $(NAMESPACE) \
		-f $(DECRYPTED_SECRETS)

verify: ## Run runtime assertions against the deployed release; exits non-zero on any failure
	@echo "==> running verification checks"
	./scripts/verify.sh $(RELEASE) $(NAMESPACE)

verify-gitops: ## Apply gitops/ manifests and assert the ArgoCD Application reaches Synced/Healthy
	@echo "==> running GitOps verification checks"
	# Requires `make argocd` first, and — while this repo is private — a
	# registered repo credential (see gitops/application.yaml's comment
	# and scripts/verify-gitops.sh). Separate from `make verify`: this
	# proves the ArgoCD/PostSync-hook path specifically, not the plain
	# Helm path.
	./scripts/verify-gitops.sh

uninstall: ## Remove the Helm release and its PVC
	@echo "==> uninstalling release '$(RELEASE)'"
	helm uninstall $(RELEASE) --namespace $(NAMESPACE)
	# `helm uninstall` deliberately does not delete PVCs — that's the
	# correct default for a StatefulSet in general, since it protects data
	# from an accidental `helm uninstall` on a release you meant to keep.
	# But it means a stale PVC survives with whatever POSTGRES_PASSWORD was
	# baked into it at first boot (the official postgres image only runs
	# its init scripts — including setting the password — on an empty
	# PGDATA, so a later `make secrets-encrypt` with a new password is
	# silently ignored on next install and auth fails with a confusing
	# error). This is a disposable local dev/demo stack, so we delete the
	# PVC explicitly here to make `make uninstall && make install` behave
	# like a real fresh install. Do NOT do this in production — see
	# docs/decisions.md "PVC lifecycle".
	kubectl delete pvc -n $(NAMESPACE) -l app.kubernetes.io/instance=$(RELEASE) --ignore-not-found

destroy: ## Delete the kind cluster
	@echo "==> deleting kind cluster '$(CLUSTER_NAME)'"
	kind delete cluster --name $(CLUSTER_NAME)

lint: ## helm lint + helm template + yamllint + shellcheck
	@echo "==> helm lint"
	helm lint $(CHART) --set secrets.postgresPassword=lint-placeholder
	@echo "==> helm template (plain-Helm path)"
	helm template $(RELEASE) $(CHART) --set secrets.postgresPassword=lint-placeholder > /dev/null
	@echo "==> helm template (ArgoCD path)"
	helm template $(RELEASE) $(CHART) --set secrets.postgresPassword=lint-placeholder --set argocd.enabled=true > /dev/null
	@echo "==> yamllint"
	yamllint charts gitops kind .github
	@echo "==> shellcheck"
	shellcheck scripts/*.sh
