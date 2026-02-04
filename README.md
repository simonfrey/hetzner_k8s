# Hetzner K8s Cluster

3-node Kubernetes cluster (k3s) on Hetzner Cloud with Terraform + cloud-init.

```
Internet → *.k8s.simon-frey.com → Hetzner LB → Traefik Ingress → Your Apps
```

## Architecture

| Component | Implementation |
|-----------|---------------|
| IaC | Terraform with `hetznercloud/hcloud` provider |
| K8s distro | k3s (lightweight, CNCF-certified) |
| OS | Ubuntu 24.04 |
| Provisioning | cloud-init |
| Networking | Hetzner Private Network (10.0.0.0/16, eu-central zone) |
| Load Balancer | Hetzner Cloud LB11 (TCP passthrough + proxy protocol) |
| Ingress | Traefik (built into k3s) |
| TLS | cert-manager + Let's Encrypt (HTTP-01 per service) |
| Cloud integration | Hetzner CCM + CSI |
| Auto-scaling | Cluster Autoscaler (0-5 workers) |

## Cost

| Resource | Spec | Monthly    |
|----------|------|------------|
| Control plane | cx33 (always on) | €5.94      |
| Load balancer | lb11 | €5.39      |
| **Base cost** | | **€9.38**  |
| Workers (0-5) | cx33 (on demand) | €0-30      |
| **Max cost** | 5 workers | **€29.33** |

## Quick Start

### 1. Prerequisites

```bash
# Install tools
brew install terraform kubectl helm   # macOS
# apt install terraform kubectl helm  # Linux

# Create SSH key
ssh-keygen -t ed25519 -f ~/.ssh/hetzner-k8s -N ""

# Create Hetzner Cloud project + API token
# → https://console.hetzner.cloud → New Project → API Tokens → Generate (Read/Write)
```

### 2. Configure

```bash
# Create .env file
echo 'HETZNER_CLOUD_API_TOKEN="your-token-here"' > .env
```

### 3. Deploy

```bash
# Source environment and export for Terraform
source .env && export TF_VAR_hcloud_token="$HETZNER_CLOUD_API_TOKEN"

# Deploy infrastructure
terraform init
terraform plan
terraform apply   # ~2 min
```

### 4. Post-Deploy Setup

```bash
# Wait for cloud-init (~3-5 min), then run:
./scripts/post-deploy.sh
```

This script:
- Waits for cloud-init completion
- Fetches kubeconfig from control plane
- Configures Traefik for proxy protocol
- Installs cert-manager
- Applies Let's Encrypt ClusterIssuer

### 5. DNS Setup

After deploy, add these records in Cloudflare (DNS-only mode, gray cloud):

| Type | Name | Value |
|------|------|-------|
| A | `*.k8s` | `<LB_IP from terraform output>` |
| A | `k8s` | `<LB_IP from terraform output>` |

### 6. Test

```bash
# Deploy example app
kubectl apply -f manifests/example-app.yaml

# Watch certificate provisioning
kubectl get certificate -n demo -w

# Test (after certificate is ready)
curl https://hello.k8s.simon-frey.com
```

## File Structure

```
hetzner-k8s/
├── main.tf                         # Servers, network, firewall, LB
├── variables.tf                    # Input variables
├── outputs.tf                      # IPs, DNS instructions
├── cloud-init-server.yaml.tpl      # Control plane provisioning
├── cloud-init-agent.yaml.tpl       # Worker provisioning
├── .env                            # API token (not in git)
├── .gitignore
├── scripts/
│   └── post-deploy.sh              # Automated post-deploy setup
└── manifests/
    ├── traefik-config.yaml         # Proxy protocol configuration
    ├── cert-manager-issuer.yaml    # Let's Encrypt ClusterIssuer
    ├── example-app.yaml            # Test deployment with auto-TLS
    └── cluster-autoscaler.yaml     # Scale workers 0-5
```

## Adding a New Service

Each service gets its own certificate automatically:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod  # ← Triggers auto-cert
spec:
  ingressClassName: traefik
  tls:
    - hosts: ["myapp.k8s.simon-frey.com"]
      secretName: myapp-tls  # ← cert-manager creates this
  rules:
    - host: myapp.k8s.simon-frey.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

## Cluster Autoscaler

The cluster can scale workers from 0-5 across three datacenters:
- fsn1 (Falkenstein)
- nbg1 (Nuremberg)
- hel1 (Helsinki)

The control plane always runs workloads (no taint) since workers can scale to 0.

To enable autoscaling:

```bash
# Apply the autoscaler manifest (follow instructions in the file)
kubectl apply -f manifests/cluster-autoscaler.yaml

# Create the required secret with your credentials
# See comments at the bottom of cluster-autoscaler.yaml
```

## Operations

```bash
# SSH into control plane
ssh -i ~/.ssh/hetzner-k8s root@$(terraform output -raw control_plane_public_ip)

# Check k3s logs
journalctl -u k3s          # on control plane
journalctl -u k3s-agent    # on workers

# View cluster nodes
kubectl get nodes -o wide

# Destroy everything
terraform destroy
```

## Troubleshooting

| Issue | Check |
|-------|-------|
| Workers not joining | `ssh root@<worker-ip> journalctl -u k3s-agent` and `cloud-init status` |
| LB health checks failing | `kubectl get pods -n kube-system` — is Traefik running? |
| Cert not issuing | `kubectl describe certificate -n <namespace>` and `kubectl logs -n cert-manager deploy/cert-manager` |
| Pods stuck Pending | `kubectl describe pod <pod>` — check resource constraints |
| No real client IPs | Verify Traefik config: `kubectl get helmchartconfig -n kube-system traefik -o yaml` |
| All kube-system pods Pending | See "Uninitialized Node Taint" section below |

### Uninitialized Node Taint

If all pods in `kube-system` are stuck in `Pending` state (including coredns, traefik, CCM), check for the `node.cloudprovider.kubernetes.io/uninitialized` taint:

```bash
kubectl describe node <control-plane-node> | grep -A5 Taints
```

**Cause**: When kubelet uses `--cloud-provider=external`, Kubernetes automatically adds this taint. The Hetzner CCM is supposed to remove it after initializing the node, but if the CCM itself can't schedule due to this taint, you get a deadlock.

**Fix**: Remove the taint manually from the control plane:

```bash
kubectl taint nodes <control-plane-node> node.cloudprovider.kubernetes.io/uninitialized-
```

This is already fixed in the current `cloud-init-server.yaml.tpl` — the control plane no longer uses `--kubelet-arg="cloud-provider=external"` to avoid this deadlock. Workers still use it for proper CCM integration (node lifecycle, labels, etc.).
