#!/usr/bin/env bash
# ============================================================================
# Post-deploy: fetch kubeconfig and wait for ArgoCD to be healthy
# ============================================================================
# All workloads are now managed by ArgoCD (installed via Terraform).
# This script just fetches the kubeconfig and shows status.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG_PATH="$ROOT_DIR/.kubeconfig"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

command -v terraform >/dev/null || die "terraform not found in PATH"
command -v kubectl   >/dev/null || die "kubectl not found in PATH"

cd "$ROOT_DIR"

# ============================================================================
# 1. Fetch kubeconfig and rewrite for WireGuard tunnel
# ============================================================================

info "Fetching kubeconfig from Terraform outputs..."
terraform output -raw kubeconfig > "$KUBECONFIG_PATH" 2>/dev/null \
  || die "Failed to fetch kubeconfig. Have you run 'terraform apply'?"
chmod 600 "$KUBECONFIG_PATH"

sed -i 's|server: https://10\.0\.1\.1:6443|server: https://127.0.0.1:6443|g' "$KUBECONFIG_PATH"
export KUBECONFIG="$KUBECONFIG_PATH"
info "Kubeconfig saved to $KUBECONFIG_PATH (API via 127.0.0.1:6443 tunnel)"

# ============================================================================
# 2. Wait for ArgoCD to be healthy
# ============================================================================

info "Waiting for ArgoCD server to be ready..."
kubectl -n argocd rollout status deployment argocd-server --timeout=300s 2>/dev/null \
  || warn "ArgoCD server not ready yet — check 'kubectl -n argocd get pods'"

# ============================================================================
# 3. Show status
# ============================================================================

echo ""
info "Cluster status:"
kubectl get nodes 2>/dev/null || true
echo ""

info "ArgoCD applications:"
kubectl -n argocd get applications 2>/dev/null || warn "ArgoCD applications not available yet"
echo ""

echo "  export KUBECONFIG=$KUBECONFIG_PATH"
echo ""
echo "  ArgoCD UI: kubectl -n argocd port-forward svc/argocd-server 8080:80"
echo "  ArgoCD password: $(terraform output -raw argocd_initial_admin_password 2>/dev/null || echo 'see terraform output')"
echo ""
echo "  Retrieve passwords:"
echo "    terraform output -raw windows_admin_password"
echo "    terraform output -raw guacamole_password"
echo "    terraform output -raw grafana_password"
echo ""
echo "  Windows ISO copy: automated during terraform apply (or manual: ./scripts/copy-windows-iso.sh)"
echo ""
