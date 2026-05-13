#!/usr/bin/env bash
# Installs minikube + kubectl and starts a local cluster using Docker driver.
# Tested: macOS arm64, Homebrew, Docker Desktop already running.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}▶ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}✗ $*${NC}"; exit 1; }

# ── pre-flight ────────────────────────────────────────────────────────────────
info "Checking Docker is running ..."
docker info &>/dev/null || die "Docker not running. Start Docker Desktop first."

# ── install minikube ──────────────────────────────────────────────────────────
if command -v minikube &>/dev/null; then
  warn "minikube already installed: $(minikube version --short)"
else
  info "Installing minikube via Homebrew ..."
  brew install minikube
fi

# ── install kubectl ───────────────────────────────────────────────────────────
if command -v kubectl &>/dev/null; then
  warn "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
else
  info "Installing kubectl via Homebrew ..."
  brew install kubectl
fi

# ── start cluster ─────────────────────────────────────────────────────────────
info "Starting minikube (driver=docker, 4 CPUs, 4 GB RAM) ..."
minikube start \
  --driver=docker \
  --cpus=4 \
  --memory=4096 \
  --disk-size=20g \
  --kubernetes-version=stable

# ── verify ────────────────────────────────────────────────────────────────────
info "Verifying cluster ..."
kubectl cluster-info
kubectl get nodes

# ── enable addons ─────────────────────────────────────────────────────────────
info "Enabling metrics-server (for kubectl top pods/nodes) ..."
minikube addons enable metrics-server

# ── done ─────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo " MINIKUBE READY"
echo "════════════════════════════════════════════════════════"
echo " Cluster info:     kubectl cluster-info"
echo " Dashboard:        minikube dashboard"
echo " Stop cluster:     minikube stop"
echo " Delete cluster:   minikube delete"
echo ""
echo " Now run the experiment:"
echo "   cd provisioning/experiment && bash run.sh"
echo "════════════════════════════════════════════════════════"
