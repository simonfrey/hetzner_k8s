#!/usr/bin/env bash
# ============================================================================
# Post-deploy: configure Kubernetes workloads after Terraform provisions infra
# ============================================================================
# Usage:
#   ./scripts/post-deploy.sh              # interactive (prompts for monitoring)
#   ./scripts/post-deploy.sh --monitoring # install monitoring stack
#   ./scripts/post-deploy.sh --no-monitoring
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG_PATH="$ROOT_DIR/.kubeconfig"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# Parse flags
INSTALL_MONITORING=""
for arg in "$@"; do
  case "$arg" in
    --monitoring)    INSTALL_MONITORING=yes ;;
    --no-monitoring) INSTALL_MONITORING=no ;;
    -h|--help)
      echo "Usage: $0 [--monitoring|--no-monitoring]"
      exit 0
      ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

# ============================================================================
# Prerequisites
# ============================================================================

command -v terraform >/dev/null || die "terraform not found in PATH"
command -v kubectl   >/dev/null || die "kubectl not found in PATH"
command -v helm      >/dev/null || die "helm not found in PATH (needed for cert-manager and monitoring)"

cd "$ROOT_DIR"

# ============================================================================
# 1. Fetch kubeconfig from Terraform
# ============================================================================

info "Fetching kubeconfig from Terraform outputs..."
terraform output -raw kubeconfig > "$KUBECONFIG_PATH" 2>/dev/null \
  || die "Failed to fetch kubeconfig. Have you run 'terraform apply'?"
chmod 600 "$KUBECONFIG_PATH"
export KUBECONFIG="$KUBECONFIG_PATH"
info "Kubeconfig saved to $KUBECONFIG_PATH"

# ============================================================================
# 2. Wait for nodes to be Ready
# ============================================================================

info "Waiting for nodes to be Ready..."
TIMEOUT=300
ELAPSED=0
until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    die "Timeout waiting for nodes to be Ready (${TIMEOUT}s)"
  fi
done
kubectl get nodes
info "Nodes are Ready."

# ============================================================================
# 3. Apply Traefik config (proxy protocol for Hetzner LB)
# ============================================================================

info "Applying Traefik HelmChartConfig..."
kubectl apply -f manifests/traefik-config.yaml

info "Restarting Traefik to pick up config..."
kubectl -n kube-system rollout restart deployment traefik 2>/dev/null \
  || kubectl -n kube-system rollout restart daemonset traefik 2>/dev/null \
  || warn "Could not restart Traefik — it may pick up the config on its own"

# ============================================================================
# 4. Install cert-manager via Helm
# ============================================================================

info "Installing cert-manager..."
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack

if helm status cert-manager -n cert-manager &>/dev/null; then
  info "cert-manager already installed, upgrading..."
  helm upgrade cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --set crds.enabled=true \
    --set startupapicheck.enabled=false \
    --wait --timeout 10m
else
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --set startupapicheck.enabled=false \
    --wait --timeout 10m
fi
info "cert-manager installed."

# ============================================================================
# 5. Wait for cert-manager webhook to be ready
# ============================================================================

info "Waiting for cert-manager webhook..."
kubectl -n cert-manager rollout status deployment cert-manager-webhook --timeout=120s
sleep 5  # extra buffer for webhook to register

# ============================================================================
# 6. Apply ClusterIssuers
# ============================================================================

info "Applying Let's Encrypt ClusterIssuers..."
# Retry loop — the webhook can take a moment to start serving
for i in $(seq 1 12); do
  if kubectl apply -f manifests/cert-manager-issuer.yaml 2>/dev/null; then
    break
  fi
  if [ "$i" -eq 12 ]; then
    die "Failed to apply ClusterIssuers after 60s"
  fi
  warn "Waiting for cert-manager CRDs to be ready..."
  sleep 5
done
info "ClusterIssuers applied."

# ============================================================================
# 7. Set up cluster autoscaler
# ============================================================================

info "Setting up cluster autoscaler..."

# Fetch dynamic values from Terraform outputs
HCLOUD_TOKEN="$(terraform output -raw hcloud_token 2>/dev/null)" \
  || die "Failed to read hcloud_token from Terraform outputs. Add: output \"hcloud_token\" { value = var.hcloud_token; sensitive = true }"
CLOUD_INIT_B64="$(terraform output -raw worker_cloud_init_base64 2>/dev/null)" \
  || die "Failed to read worker_cloud_init_base64 from Terraform outputs"
CLUSTER_NAME="$(terraform output -raw cluster_name 2>/dev/null)" \
  || die "Failed to read cluster_name from Terraform outputs"

NETWORK_NAME="${CLUSTER_NAME}-network"
SSH_KEY_NAME="${CLUSTER_NAME}-key"
FIREWALL_NAME="${CLUSTER_NAME}-fw"

# Apply the manifest (namespace, RBAC, deployment)
kubectl apply -f manifests/cluster-autoscaler.yaml

# Create or update the secret with live values
kubectl -n cluster-autoscaler create secret generic hcloud-autoscaler \
  --from-literal=token="$HCLOUD_TOKEN" \
  --from-literal=cloud-init="$CLOUD_INIT_B64" \
  --from-literal=network="$NETWORK_NAME" \
  --from-literal=ssh-key="$SSH_KEY_NAME" \
  --from-literal=firewall="$FIREWALL_NAME" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart the autoscaler to pick up the secret
kubectl -n cluster-autoscaler rollout restart deployment cluster-autoscaler
info "Cluster autoscaler deployed."

# ============================================================================
# 8. Optionally install monitoring (kube-prometheus-stack)
# ============================================================================

if [ -z "$INSTALL_MONITORING" ]; then
  echo ""
  read -rp "Install monitoring stack (kube-prometheus-stack)? [y/N] " answer
  case "$answer" in
    [yY]*) INSTALL_MONITORING=yes ;;
    *)     INSTALL_MONITORING=no ;;
  esac
fi

if [ "$INSTALL_MONITORING" = "yes" ]; then
  info "Installing kube-prometheus-stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update prometheus-community

  # Create namespace with required label
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace monitoring pod-security.kubernetes.io/enforce=privileged --overwrite

  if helm status kube-prometheus-stack -n monitoring &>/dev/null; then
    info "kube-prometheus-stack already installed, upgrading..."
    helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      -f manifests/monitoring-values.yaml \
      --wait --timeout 15m
  else
    helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      -f manifests/monitoring-values.yaml \
      --wait --timeout 15m
  fi
  info "Monitoring stack installed."

  info "Applying monitoring ingress resources..."
  kubectl apply -f manifests/monitoring-ingress.yaml

  info "Grafana: kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
  info "Default credentials: admin / admin"
else
  info "Skipping monitoring stack. Install later with: $0 --monitoring"
fi

# ============================================================================
# Done
# ============================================================================

echo ""
info "Post-deploy complete!"
echo ""
echo "  export KUBECONFIG=$KUBECONFIG_PATH"
echo "  kubectl get nodes"
echo "  kubectl get clusterissuer"
echo "  kubectl -n cluster-autoscaler get deploy"
echo ""
echo "  Deploy test app:  kubectl apply -f manifests/example-app.yaml"
echo ""
