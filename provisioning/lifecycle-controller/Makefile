# Lifecycle Controller — Test Targets
#
# Quick reference:
#   make test            unit tests only (no cluster, no binaries needed)
#   make test-integration  integration tests (needs setup-envtest)
#   make test-e2e        E2E tests (needs running minikube + deployed controller)
#   make test-all        all three layers in sequence
#   make envtest-setup   install API server binaries for integration tests

ENVTEST_K8S_VERSION ?= 1.29
ENVTEST_BIN_DIR     ?= $(HOME)/.local/share/kubebuilder-envtest
KUBEBUILDER_ASSETS  ?= $(shell setup-envtest use $(ENVTEST_K8S_VERSION) --bin-dir $(ENVTEST_BIN_DIR) -p path 2>/dev/null)

.PHONY: test test-integration test-e2e test-all envtest-setup fmt vet

## ── Unit tests (fake client — no cluster, no binaries) ───────────────────────
test:
	@echo "▶ Running unit tests ..."
	go test ./controller/... -v -count=1 -timeout 30s
	@echo "✓ Unit tests passed."

## ── Integration tests (envtest — real API server, no cluster) ────────────────
## Requires: make envtest-setup (run once)
test-integration: envtest-check
	@echo "▶ Running integration tests (KUBEBUILDER_ASSETS=$(KUBEBUILDER_ASSETS)) ..."
	KUBEBUILDER_ASSETS="$(KUBEBUILDER_ASSETS)" \
	  go test ./integration/... -v -count=1 -timeout 120s
	@echo "✓ Integration tests passed."

envtest-check:
	@if [ -z "$(KUBEBUILDER_ASSETS)" ]; then \
	  echo "ERROR: KUBEBUILDER_ASSETS not set. Run: make envtest-setup"; exit 1; \
	fi

## ── E2E tests (live minikube + deployed controller) ──────────────────────────
test-e2e:
	@echo "▶ Running E2E tests against minikube ..."
	bash test/e2e.sh
	@echo "✓ E2E tests passed."

## ── All layers ───────────────────────────────────────────────────────────────
test-all: test test-integration test-e2e
	@echo ""
	@echo "✓ All test layers passed."

## ── Install envtest binaries (one-time setup) ────────────────────────────────
envtest-setup:
	@echo "▶ Installing setup-envtest ..."
	go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest
	@echo "▶ Downloading API server binaries for k8s $(ENVTEST_K8S_VERSION) ..."
	setup-envtest use $(ENVTEST_K8S_VERSION) --bin-dir $(ENVTEST_BIN_DIR)
	@echo "✓ Done. Binaries at: $(ENVTEST_BIN_DIR)"

## ── Code quality ─────────────────────────────────────────────────────────────
fmt:
	go fmt ./...

vet:
	go vet ./...
