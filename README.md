# Hetzner K8s Cluster

Production-ready Kubernetes cluster (k3s) on Hetzner Cloud with full Infrastructure as Code.

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
| VPN Access | wireproxy (userspace WireGuard, K8s API restricted to VPN) |
| Monitoring | kube-prometheus-stack (Prometheus + Grafana) |

## Security Features

- **K8s API Access**: Restricted to WireGuard tunnel via wireproxy (port 6443 not publicly exposed)
- **etcd Encryption**: Secrets encrypted at rest
- **kubeconfig Permissions**: 600 (owner only)
- **Pod Security Standards**: Restricted policy enforced on demo namespace
- **Security Contexts**: All workloads run as non-root with dropped capabilities
- **Firewall**: Explicit allow-list for all ports (no "any" rules)
- **RBAC**: Minimal permissions for cluster autoscaler
- **Resource Quotas**: Limit namespace resource consumption
- **PV Reclaim Policy**: Retain (prevents accidental data loss)

## Cost

| Resource | Spec | Monthly    |
|----------|------|------------|
| Control plane | cx23 (always on) | ~€5      |
| Load balancer | lb11 | ~€5      |
| **Base cost** | | **~€10**  |
| Workers (0-5) | cx23 (on demand) | €0-25      |
| **Max cost** | 5 workers | **~€35** |

## Quick Start

### 1. Prerequisites

```bash
# Install tools
brew install terraform kubectl helm wireproxy jq  # macOS
# apt install terraform kubectl helm jq && go install github.com/pufferffish/wireproxy/cmd/wireproxy@latest  # Linux

# Create SSH key
ssh-keygen -t ed25519 -f ~/.ssh/hetzner-k8s -N ""

# Create Wireguard keys
mkdir -p ~/.wireguard
wg genkey | tee ~/.wireguard/hetzner-k8s-private | wg pubkey > ~/.wireguard/hetzner-k8s-public

# Create Hetzner Cloud project + API token
# → https://console.hetzner.cloud → New Project → API Tokens → Generate (Read/Write)
```

### 2. Configure

```bash
# Create .env file
cat > .env << 'EOF'
HETZNER_CLOUD_API_TOKEN="your-token-here"
EOF
```

### 3. Deploy Infrastructure

Terraform provisions servers, network, load balancer, firewall, and a wireproxy tunnel (userspace WireGuard — no `sudo` required). Requires `wireproxy` installed.

```bash
# Source environment and export for Terraform
source .env
export TF_VAR_hcloud_token="$HETZNER_CLOUD_API_TOKEN"
export TF_VAR_wireguard_client_public_key="$(cat ~/.wireguard/hetzner-k8s-public)"
export TF_VAR_wireguard_client_private_key="$(cat ~/.wireguard/hetzner-k8s-private)"

# Deploy infrastructure (servers, network, LB, firewall, WireGuard)
terraform init
terraform plan
terraform apply   # ~5-10 min (includes waiting for k3s + WireGuard setup)
```

Terraform writes `.wireproxy.conf` in the project root and starts wireproxy in the background (PID in `.wireproxy.pid`). It creates a TCP tunnel from `127.0.0.1:6443` to the K8s API over WireGuard. On `terraform destroy`, the process is stopped and config files cleaned up automatically.

### 4. Configure Kubernetes Workloads

The post-deploy script configures everything that runs inside the cluster: Traefik, cert-manager, cluster autoscaler, and optionally monitoring.

```bash
./scripts/post-deploy.sh              # interactive (prompts for monitoring)
./scripts/post-deploy.sh --monitoring  # include monitoring stack
./scripts/post-deploy.sh --no-monitoring
```

This automatically saves the kubeconfig to `.kubeconfig` in the project root.

### 5. Configure kubectl (manual)

`post-deploy.sh` handles kubeconfig automatically, but you can also set it up manually:

```bash
# Save kubeconfig
terraform output -raw kubeconfig > ~/.kube/hetzner-k8s.yaml
chmod 600 ~/.kube/hetzner-k8s.yaml

# Use it
export KUBECONFIG=~/.kube/hetzner-k8s.yaml
kubectl get nodes
```

### 6. wireproxy Management

The tunnel is managed by Terraform, but you can also control it manually:

```bash
# Check if wireproxy is running
cat .wireproxy.pid && ps -p $(cat .wireproxy.pid)

# View tunnel logs
cat .wireproxy.log

# Restart manually
kill $(cat .wireproxy.pid) 2>/dev/null
nohup wireproxy -c .wireproxy.conf > .wireproxy.log 2>&1 &
echo $! > .wireproxy.pid

# Verify K8s API is reachable through tunnel
kubectl --kubeconfig .kubeconfig get nodes
```

### 7. DNS Setup

After deploy, add these records in Cloudflare (DNS-only mode, gray cloud):

| Type | Name | Value |
|------|------|-------|
| A | `*.k8s` | `<LB_IP from terraform output>` |
| A | `k8s` | `<LB_IP from terraform output>` |

### 8. Test

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
├── main.tf                         # Servers, network, firewall, LB, providers
├── variables.tf                    # Input variables with validation
├── outputs.tf                      # IPs, kubeconfig, Wireguard config
├── cloud-init-server.yaml.tpl      # Control plane provisioning
├── cloud-init-agent.yaml.tpl       # Worker provisioning
├── scripts/
│   └── post-deploy.sh              # Configures K8s workloads after terraform apply
├── manifests/
│   ├── traefik-config.yaml         # Proxy protocol config for Hetzner LB
│   ├── cert-manager-issuer.yaml    # Let's Encrypt ClusterIssuer
│   ├── cluster-autoscaler.yaml     # Autoscaler namespace, RBAC, deployment
│   ├── monitoring-values.yaml      # Helm values for kube-prometheus-stack
│   └── example-app.yaml            # Test deployment with security best practices
├── .env                            # API token (not in git)
└── .gitignore
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

## Monitoring (Optional)

Monitoring is not installed by default. Install it via the post-deploy script or manually with Helm:

```bash
# Via post-deploy script
./scripts/post-deploy.sh --monitoring

# Or manually with Helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f manifests/monitoring-values.yaml
```

Access Grafana at `https://grafana.k8s.simon-frey.com` (after DNS setup).

Default credentials: `admin` / `admin` (change in production!)

Or use port-forward:
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# Open http://localhost:3000
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

# View autoscaler logs
kubectl -n cluster-autoscaler logs -f deployment/cluster-autoscaler

# Stop wireproxy tunnel
kill $(cat .wireproxy.pid) 2>/dev/null

# Destroy everything (K8s resources are ephemeral, no separate teardown needed)
terraform destroy
```

## Troubleshooting

| Issue | Check |
|-------|-------|
| Can't connect to API | Is wireproxy running? `ps -p $(cat .wireproxy.pid)` and check `.wireproxy.log` |
| Workers not joining | `ssh root@<worker-ip> journalctl -u k3s-agent` and `cloud-init status` |
| LB health checks failing | `kubectl get pods -n kube-system` — is Traefik running? |
| Cert not issuing | `kubectl describe certificate -n <namespace>` and `kubectl logs -n cert-manager deploy/cert-manager` |
| Pods stuck Pending | `kubectl describe pod <pod>` — check resource constraints or control plane taint |
| No real client IPs | Verify Traefik config: `kubectl get helmchartconfig -n kube-system traefik -o yaml` |
| Monitoring not working | Check `kubectl -n monitoring get pods` |

### Control Plane Taint

The control plane has a `NoSchedule` taint to prefer running workloads on workers. System components (autoscaler, monitoring) have tolerations to run on it.

If workers scale to zero, workloads with the toleration will run on the control plane.

## Known Limitations

- **Single control plane**: No HA (acceptable for dev/small production clusters)
- **No Network Policies**: Planned with service mesh
- **wireproxy required**: K8s API not accessible without the wireproxy tunnel
- **SSH key path**: Assumes `~/.ssh/hetzner-k8s`

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `hcloud_token` | Hetzner Cloud API token | (required) |
| `cluster_name` | Name prefix for resources | `hetzner-k8s` |
| `server_type` | Server type for nodes | `cx23` |
| `wireguard_client_public_key` | Your Wireguard public key | (required for VPN) |
| `wireguard_client_private_key` | Your Wireguard private key (sensitive) | (required for VPN) |
| `enable_wireguard` | Enable Wireguard VPN | `true` |
| `autoscaler_min_nodes` | Minimum workers | `0` |
| `autoscaler_max_nodes` | Maximum workers | `5` |

See `variables.tf` for all options.
