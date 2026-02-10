#!/usr/bin/env bash
# ============================================================================
# Post-deploy: configure Kubernetes workloads after Terraform provisions infra
# ============================================================================
# Usage:
#   ./scripts/post-deploy.sh              # interactive (prompts for monitoring)
#   ./scripts/post-deploy.sh --monitoring  # install monitoring stack
#   ./scripts/post-deploy.sh --no-monitoring
# ============================================================================
# Talos boots with CNI=none and proxy disabled. This script installs:
#   1. Reads Terraform outputs (cluster_name, letsencrypt_email)
#   2. Fetches kubeconfig
#   3. Cilium (CNI) — MUST be first, nodes are NotReady without it
#   4. Hetzner CCM — removes cloud-provider taint
#   5. Hetzner CSI — enables persistent volumes
#   6. (wait for nodes)
#   7. metrics-server — required for HPA CPU/memory targets
#   8. Traefik — ingress controller (LB name templated from cluster_name)
#   9. cert-manager — TLS certificates (email templated from letsencrypt_email)
#  10. Cluster autoscaler — scales workers
#  11. Monitoring (optional)
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
command -v helm      >/dev/null || die "helm not found in PATH"

cd "$ROOT_DIR"

# ============================================================================
# Pinned Helm chart versions (for reproducible deploys from zero)
# ============================================================================

CILIUM_VERSION="1.19.0"
HCLOUD_CCM_VERSION="1.29.2"
HCLOUD_CSI_VERSION="2.18.3"
METRICS_SERVER_VERSION="3.12.2"
TRAEFIK_VERSION="39.0.0"
CERT_MANAGER_VERSION="v1.19.3"
KUBE_PROMETHEUS_VERSION="81.5.0"

# ============================================================================
# 1. Read Terraform outputs needed throughout the script
# ============================================================================

info "Reading Terraform outputs..."
CLUSTER_NAME="$(terraform output -raw cluster_name 2>/dev/null)" \
  || die "Failed to read cluster_name from Terraform outputs"
LETSENCRYPT_EMAIL="$(terraform output -raw letsencrypt_email 2>/dev/null)" \
  || die "Failed to read letsencrypt_email from Terraform outputs"

# ============================================================================
# 2. Fetch kubeconfig from Terraform and rewrite API URL to local tunnel
# ============================================================================

info "Fetching kubeconfig from Terraform outputs..."
terraform output -raw kubeconfig > "$KUBECONFIG_PATH" 2>/dev/null \
  || die "Failed to fetch kubeconfig. Have you run 'terraform apply'?"
chmod 600 "$KUBECONFIG_PATH"

# Rewrite server URL to use WireGuard tunnel
sed -i 's|server: https://10\.0\.1\.1:6443|server: https://127.0.0.1:6443|g' "$KUBECONFIG_PATH"

export KUBECONFIG="$KUBECONFIG_PATH"
info "Kubeconfig saved to $KUBECONFIG_PATH (API via 127.0.0.1:6443 tunnel)"

# ============================================================================
# 3. Install Cilium (CNI) — MUST be first, nodes are NotReady without it
# ============================================================================

info "Installing Cilium CNI..."
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update cilium

if helm status cilium -n kube-system &>/dev/null; then
  info "Cilium already installed, upgrading..."
  helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --version "$CILIUM_VERSION" \
    --set ipam.mode=kubernetes \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set kubeProxyReplacement=true \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --wait --timeout 10m
else
  helm install cilium cilium/cilium \
    --namespace kube-system \
    --version "$CILIUM_VERSION" \
    --set ipam.mode=kubernetes \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set kubeProxyReplacement=true \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --wait --timeout 10m
fi
info "Cilium installed."

# ============================================================================
# 4. Wait for nodes to be Ready
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
# 5. Install Hetzner Cloud Controller Manager (removes cloud-provider taint)
# ============================================================================

info "Installing Hetzner Cloud Controller Manager..."
helm repo add hcloud https://charts.hetzner.cloud 2>/dev/null || true
helm repo update hcloud

if helm status hcloud-cloud-controller-manager -n kube-system &>/dev/null; then
  info "Hetzner CCM already installed, upgrading..."
  helm upgrade hcloud-cloud-controller-manager hcloud/hcloud-cloud-controller-manager \
    --namespace kube-system \
    --version "$HCLOUD_CCM_VERSION" \
    --set networking.enabled=true \
    --set networking.clusterCIDR=10.244.0.0/16 \
    --set env.HCLOUD_TOKEN.valueFrom.secretKeyRef.name=hcloud \
    --set env.HCLOUD_TOKEN.valueFrom.secretKeyRef.key=token \
    --set env.HCLOUD_NETWORK.valueFrom.secretKeyRef.name=hcloud \
    --set env.HCLOUD_NETWORK.valueFrom.secretKeyRef.key=network \
    --wait --timeout 5m
else
  helm install hcloud-cloud-controller-manager hcloud/hcloud-cloud-controller-manager \
    --namespace kube-system \
    --version "$HCLOUD_CCM_VERSION" \
    --set networking.enabled=true \
    --set networking.clusterCIDR=10.244.0.0/16 \
    --set env.HCLOUD_TOKEN.valueFrom.secretKeyRef.name=hcloud \
    --set env.HCLOUD_TOKEN.valueFrom.secretKeyRef.key=token \
    --set env.HCLOUD_NETWORK.valueFrom.secretKeyRef.name=hcloud \
    --set env.HCLOUD_NETWORK.valueFrom.secretKeyRef.key=network \
    --wait --timeout 5m
fi
info "Hetzner CCM installed."

# ============================================================================
# 6. Install Hetzner CSI Driver (enables persistent volumes)
# ============================================================================

info "Installing Hetzner CSI Driver..."

if helm status hcloud-csi -n kube-system &>/dev/null; then
  info "Hetzner CSI already installed, upgrading..."
  helm upgrade hcloud-csi hcloud/hcloud-csi \
    --namespace kube-system \
    --version "$HCLOUD_CSI_VERSION" \
    --set storageClasses[0].name=hcloud-volumes \
    --set storageClasses[0].defaultStorageClass=true \
    --set storageClasses[0].reclaimPolicy=Retain \
    --wait --timeout 5m
else
  helm install hcloud-csi hcloud/hcloud-csi \
    --namespace kube-system \
    --version "$HCLOUD_CSI_VERSION" \
    --set storageClasses[0].name=hcloud-volumes \
    --set storageClasses[0].defaultStorageClass=true \
    --set storageClasses[0].reclaimPolicy=Retain \
    --wait --timeout 5m
fi
info "Hetzner CSI installed."

# ============================================================================
# 7. Install metrics-server (required for HPA CPU/memory targets)
# ============================================================================

info "Installing metrics-server..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo update metrics-server

if helm status metrics-server -n kube-system &>/dev/null; then
  info "metrics-server already installed, upgrading..."
  helm upgrade metrics-server metrics-server/metrics-server \
    --namespace kube-system \
    --version "$METRICS_SERVER_VERSION" \
    --set args={--kubelet-insecure-tls} \
    --wait --timeout 5m
else
  helm install metrics-server metrics-server/metrics-server \
    --namespace kube-system \
    --version "$METRICS_SERVER_VERSION" \
    --set args={--kubelet-insecure-tls} \
    --wait --timeout 5m
fi
info "metrics-server installed."

# ============================================================================
# 8. Install Traefik via Helm
# ============================================================================

info "Installing Traefik..."
helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
helm repo update traefik

# Template the LB name into traefik values
TRAEFIK_VALUES=$(mktemp)
sed "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" manifests/traefik-values.yaml > "$TRAEFIK_VALUES"
trap "rm -f $TRAEFIK_VALUES" EXIT

if helm status traefik -n traefik &>/dev/null; then
  info "Traefik already installed, upgrading..."
  helm upgrade traefik traefik/traefik \
    --namespace traefik \
    --version "$TRAEFIK_VERSION" \
    -f "$TRAEFIK_VALUES" \
    --wait --timeout 5m
else
  helm install traefik traefik/traefik \
    --namespace traefik --create-namespace \
    --version "$TRAEFIK_VERSION" \
    -f "$TRAEFIK_VALUES" \
    --wait --timeout 5m
fi
rm -f "$TRAEFIK_VALUES"
info "Traefik installed."

# ============================================================================
# 9. Install cert-manager via Helm
# ============================================================================

info "Installing cert-manager..."
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack

if helm status cert-manager -n cert-manager &>/dev/null; then
  info "cert-manager already installed, upgrading..."
  helm upgrade cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true \
    --set startupapicheck.enabled=false \
    --wait --timeout 10m
else
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true \
    --set startupapicheck.enabled=false \
    --wait --timeout 10m
fi
info "cert-manager installed."

# ============================================================================
# 10. Wait for cert-manager webhook and apply ClusterIssuers
# ============================================================================

info "Waiting for cert-manager webhook..."
kubectl -n cert-manager rollout status deployment cert-manager-webhook --timeout=120s
sleep 5  # extra buffer for webhook to register

info "Applying Let's Encrypt ClusterIssuers..."
# Template the email into cert-manager issuer manifest
ISSUER_MANIFEST=$(mktemp)
sed "s/__LETSENCRYPT_EMAIL__/${LETSENCRYPT_EMAIL}/g" manifests/cert-manager-issuer.yaml > "$ISSUER_MANIFEST"

for i in $(seq 1 12); do
  if kubectl apply -f "$ISSUER_MANIFEST" 2>/dev/null; then
    break
  fi
  if [ "$i" -eq 12 ]; then
    die "Failed to apply ClusterIssuers after 60s"
  fi
  warn "Waiting for cert-manager CRDs to be ready..."
  sleep 5
done
rm -f "$ISSUER_MANIFEST"
info "ClusterIssuers applied."

# ============================================================================
# 11. Set up cluster autoscaler
# ============================================================================

info "Setting up cluster autoscaler..."

HCLOUD_TOKEN="$(terraform output -raw hcloud_token 2>/dev/null)" \
  || die "Failed to read hcloud_token from Terraform outputs"
CLOUD_INIT_B64="$(terraform output -raw worker_machine_config_base64 2>/dev/null)" \
  || die "Failed to read worker_machine_config_base64 from Terraform outputs"
TALOS_IMAGE_ID="$(terraform output -raw talos_image_id 2>/dev/null)" \
  || die "Failed to read talos_image_id from Terraform outputs"

NETWORK_NAME="${CLUSTER_NAME}-network"
FIREWALL_NAME="${CLUSTER_NAME}-fw"

# Apply the manifest (namespace, RBAC, deployment)
kubectl apply -f manifests/cluster-autoscaler.yaml

# Create or update the secret with live values
kubectl -n cluster-autoscaler create secret generic hcloud-autoscaler \
  --from-literal=token="$HCLOUD_TOKEN" \
  --from-literal=cloud-init="$CLOUD_INIT_B64" \
  --from-literal=network="$NETWORK_NAME" \
  --from-literal=firewall="$FIREWALL_NAME" \
  --from-literal=image="$TALOS_IMAGE_ID" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart the autoscaler to pick up the secret
kubectl -n cluster-autoscaler rollout restart deployment cluster-autoscaler
info "Cluster autoscaler deployed."

# ============================================================================
# 12. Optionally install monitoring (kube-prometheus-stack)
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

  # Generate a secure random Grafana admin password
  GRAFANA_PASSWORD=$(openssl rand -base64 18)

  # Create namespace with required label
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace monitoring pod-security.kubernetes.io/enforce=privileged --overwrite

  if helm status kube-prometheus-stack -n monitoring &>/dev/null; then
    info "kube-prometheus-stack already installed, upgrading..."
    helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      --version "$KUBE_PROMETHEUS_VERSION" \
      -f manifests/monitoring-values.yaml \
      --set grafana.adminPassword="$GRAFANA_PASSWORD" \
      --wait --timeout 15m
  else
    helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      --version "$KUBE_PROMETHEUS_VERSION" \
      -f manifests/monitoring-values.yaml \
      --set grafana.adminPassword="$GRAFANA_PASSWORD" \
      --wait --timeout 15m
  fi
  info "Monitoring stack installed."

  info "Grafana: kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
  info "Grafana credentials: admin / $GRAFANA_PASSWORD"
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
