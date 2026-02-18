#!/usr/bin/env bash
# ============================================================================
# Copy Windows ISO into PVC via temporary pod
# CDI upload mangles ISOs — this uses kubectl cp for byte-for-byte copy
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG_PATH="$ROOT_DIR/.kubeconfig"
ISO_PATH="${1:-ISOs/SERVER_EVAL_x64FRE_de-de.iso}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found in PATH"

if [ -f "$KUBECONFIG_PATH" ]; then
  export KUBECONFIG="$KUBECONFIG_PATH"
fi

cd "$ROOT_DIR"

[ -f "$ISO_PATH" ] || die "ISO not found at $ISO_PATH. Usage: $0 [path-to-iso]"

ISO_SIZE="$(stat -c%s "$ISO_PATH")"
info "ISO: $ISO_PATH ($((ISO_SIZE / 1024 / 1024)) MB)"

# Stop VM so the PVC is not in use
info "Stopping VM to release ISO PVC..."
kubectl get vmi windows-server-2022 -n windows &>/dev/null && \
  kubectl patch vm windows-server-2022 -n windows --type merge -p '{"spec":{"runStrategy":"Stopped"}}' && \
  kubectl wait --for=delete vmi/windows-server-2022 -n windows --timeout=120s 2>/dev/null || true

# Wait for PVCs to be bound
info "Waiting for windows-iso PVC to be Bound..."
ELAPSED=0
until kubectl get pvc windows-iso -n windows -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Bound"; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [ "$ELAPSED" -ge 300 ]; then
    die "Timeout waiting for windows-iso PVC to be Bound"
  fi
done

info "Waiting for windows-os-disk PVC to be Bound..."
ELAPSED=0
until kubectl get pvc windows-os-disk -n windows -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Bound"; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [ "$ELAPSED" -ge 300 ]; then
    die "Timeout waiting for windows-os-disk PVC to be Bound"
  fi
done

# Create a temporary pod on the kubevirt node to copy the ISO into the PVC
info "Creating iso-loader pod..."
kubectl apply -f - <<'LOADER_EOF'
apiVersion: v1
kind: Pod
metadata:
  name: iso-loader
  namespace: windows
spec:
  nodeSelector:
    node.kubernetes.io/instance-type: ccx23
  tolerations:
    - key: kubevirt
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: iso-loader
      image: alpine
      command: ["sleep", "7200"]
      volumeMounts:
        - name: iso
          mountPath: /mnt/iso
        - name: os-disk
          mountPath: /mnt/os-disk
  volumes:
    - name: iso
      persistentVolumeClaim:
        claimName: windows-iso
    - name: os-disk
      persistentVolumeClaim:
        claimName: windows-os-disk
LOADER_EOF

info "Waiting for iso-loader pod to be ready..."
kubectl wait --for=condition=Ready pod/iso-loader -n windows --timeout=300s

info "Copying Windows ISO into PVC ($(du -h "$ISO_PATH" | cut -f1), this takes several minutes)..."
kubectl cp "$ISO_PATH" windows/iso-loader:/mnt/iso/disk.img

# Verify the copy succeeded
COPIED_SIZE="$(kubectl exec -n windows iso-loader -- stat -c%s /mnt/iso/disk.img 2>/dev/null || echo 0)"
if [ "$ISO_SIZE" != "$COPIED_SIZE" ]; then
  kubectl delete pod iso-loader -n windows --wait=false
  die "ISO copy failed: expected $ISO_SIZE bytes, got $COPIED_SIZE bytes"
fi
info "ISO copied successfully ($COPIED_SIZE bytes)."

# Wipe first 1MB of OS disk to clear any leftover GPT/MBR partition table
info "Wiping OS disk partition table (first 1MB)..."
kubectl exec -n windows iso-loader -- dd if=/dev/zero of=/mnt/os-disk/disk.img bs=1M count=1 conv=notrunc
info "OS disk partition table wiped."

# Clean up loader pod
kubectl delete pod iso-loader -n windows --wait
info "iso-loader pod deleted."

# Start the VM
info "Starting Windows VM..."
kubectl patch vm windows-server-2022 -n windows --type merge -p '{"spec":{"runStrategy":"Always"}}'
info "Windows ISO copied. VM is starting."
echo ""
echo "  Note: software emulation (no KVM) — installation is slow (~60+ min)."
echo "  Monitor progress: virtctl vnc windows-server-2022 -n windows"
