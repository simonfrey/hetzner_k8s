#!/bin/bash
# Post-deploy script for Hetzner K8s cluster
# Run this after terraform apply completes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ============================================================================
# Load environment
# ============================================================================

if [[ -f "$PROJECT_DIR/.env" ]]; then
    source "$PROJECT_DIR/.env"
    export HCLOUD_TOKEN="${HETZNER_CLOUD_API_TOKEN:-}"
fi

if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
    error "HCLOUD_TOKEN not set. Create .env with HETZNER_CLOUD_API_TOKEN"
fi

# ============================================================================
# Get control plane IP from Terraform
# ============================================================================

cd "$PROJECT_DIR"

if ! command -v terraform &> /dev/null; then
    error "terraform not found. Install it first."
fi

log "Getting control plane IP from Terraform..."
CP_IP=$(terraform output -raw control_plane_public_ip 2>/dev/null) || error "Run 'terraform apply' first"

log "Control plane IP: $CP_IP"

# ============================================================================
# Wait for cloud-init to complete
# ============================================================================

SSH_KEY="${SSH_KEY:-$HOME/.ssh/hetzner-k8s}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

log "Waiting for cloud-init to complete on control plane..."
for i in {1..60}; do
    if ssh $SSH_OPTS -i "$SSH_KEY" "root@$CP_IP" "cloud-init status --wait" 2>/dev/null | grep -q "done"; then
        log "Cloud-init completed!"
        break
    fi
    if [[ $i -eq 60 ]]; then
        error "Timeout waiting for cloud-init"
    fi
    echo -n "."
    sleep 10
done

# ============================================================================
# Fetch kubeconfig
# ============================================================================

KUBECONFIG_DIR="$HOME/.kube"
KUBECONFIG_FILE="$KUBECONFIG_DIR/hetzner-k8s.yaml"

mkdir -p "$KUBECONFIG_DIR"

log "Fetching kubeconfig..."
scp $SSH_OPTS -i "$SSH_KEY" "root@$CP_IP:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG_FILE"

# Update server address
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|127.0.0.1|$CP_IP|g" "$KUBECONFIG_FILE"
else
    sed -i "s|127.0.0.1|$CP_IP|g" "$KUBECONFIG_FILE"
fi

chmod 600 "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

log "Kubeconfig saved to: $KUBECONFIG_FILE"

# ============================================================================
# Verify cluster
# ============================================================================

log "Verifying cluster..."
kubectl get nodes || error "Failed to connect to cluster"

# Wait for all nodes to be Ready
log "Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# ============================================================================
# Apply Traefik proxy protocol configuration
# ============================================================================

log "Configuring Traefik for proxy protocol..."
kubectl apply -f "$PROJECT_DIR/manifests/traefik-config.yaml"

# Restart Traefik to pick up changes
log "Restarting Traefik..."
kubectl -n kube-system rollout restart deployment traefik 2>/dev/null || \
kubectl -n kube-system rollout restart daemonset traefik 2>/dev/null || \
warn "Could not restart Traefik - it may be using a different deployment method"

# ============================================================================
# Install cert-manager
# ============================================================================

log "Installing cert-manager..."

if ! command -v helm &> /dev/null; then
    warn "Helm not found. Installing cert-manager via kubectl..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
else
    # Add Jetstack Helm repo
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm repo update

    # Install cert-manager
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set crds.enabled=true \
        --wait
fi

# Wait for cert-manager to be ready
log "Waiting for cert-manager..."
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=600s

# ============================================================================
# Apply ClusterIssuer
# ============================================================================

log "Applying Let's Encrypt ClusterIssuer..."
kubectl apply -f "$PROJECT_DIR/manifests/cert-manager-issuer.yaml"

# ============================================================================
# Install Cluster Autoscaler
# ============================================================================

log "Setting up cluster autoscaler..."

# Get values from terraform
CLUSTER_NAME=$(terraform output -raw cluster_name)
NETWORK_NAME="${CLUSTER_NAME}-network"
SSH_KEY_NAME="${CLUSTER_NAME}-key"
FIREWALL_NAME="${CLUSTER_NAME}-fw"

# Create namespace
kubectl create namespace cluster-autoscaler --dry-run=client -o yaml | kubectl apply -f -

# Render the cloud-init template for workers
CLOUD_INIT_RENDERED=$(terraform output -raw worker_cloud_init_base64)

# Create the autoscaler secret
kubectl create secret generic hcloud-autoscaler \
    --namespace=cluster-autoscaler \
    --from-literal=token="$HCLOUD_TOKEN" \
    --from-literal=cloud-init="$CLOUD_INIT_RENDERED" \
    --from-literal=network="$NETWORK_NAME" \
    --from-literal=ssh-key="$SSH_KEY_NAME" \
    --from-literal=firewall="$FIREWALL_NAME" \
    --dry-run=client -o yaml | kubectl apply -f -

# Apply autoscaler manifest
kubectl apply -f "$PROJECT_DIR/manifests/cluster-autoscaler.yaml"

log "Waiting for autoscaler to be ready..."
kubectl -n cluster-autoscaler wait --for=condition=Available deployment/cluster-autoscaler --timeout=120s

# ============================================================================
# Done!
# ============================================================================

LB_IP=$(terraform output -raw load_balancer_ip)

echo ""
log "================================================"
log "Post-deploy complete!"
log "================================================"
echo ""
echo "Kubeconfig: export KUBECONFIG=$KUBECONFIG_FILE"
echo ""
echo "Next steps:"
echo "  1. Add DNS records in Cloudflare:"
echo "     - A record: *.k8s -> $LB_IP"
echo "     - A record: k8s -> $LB_IP"
echo ""
echo "  2. Deploy the example app:"
echo "     kubectl apply -f manifests/example-app.yaml"
echo ""
echo "  3. Check certificate status:"
echo "     kubectl get certificate -w"
echo ""
