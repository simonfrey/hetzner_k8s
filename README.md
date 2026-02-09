# Hetzner K8s Cluster (Talos Linux)

Production-ready Kubernetes cluster on Hetzner Cloud using Talos Linux — an immutable, API-only OS purpose-built for Kubernetes.

```
Internet → *.k8s.simon-frey.com → Hetzner LB → Traefik Ingress → Your Apps
```

## Architecture

| Component | Implementation |
|-----------|---------------|
| IaC | Terraform with `hetznercloud/hcloud` + `siderolabs/talos` providers |
| OS | Talos Linux (immutable, no SSH) |
| Image Build | Packer (Hetzner snapshot with qemu-guest-agent) |
| CNI | Cilium (kube-proxy replacement) |
| Networking | Hetzner Private Network (10.0.0.0/16, eu-central zone) |
| Load Balancer | Hetzner Cloud LB11 (TCP passthrough + proxy protocol) |
| Ingress | Traefik (Helm) |
| TLS | cert-manager + Let's Encrypt (HTTP-01 per service) |
| Cloud integration | Hetzner CCM + CSI (Helm) |
| Auto-scaling | Cluster Autoscaler (0-5 workers) |
| VPN Access | wireproxy (userspace WireGuard, K8s + Talos API restricted to VPN) |
| Monitoring | kube-prometheus-stack (Prometheus + Grafana) |

## Security Features

- **No SSH**: Talos has no shell, no SSH — managed entirely via API
- **K8s API Access**: Restricted to WireGuard tunnel via wireproxy (port 6443 not publicly exposed)
- **Talos API Access**: Restricted to WireGuard tunnel (port 50000 not publicly exposed)
- **Immutable OS**: Read-only rootfs, no package manager, minimal attack surface
- **Pod Security Standards**: Restricted policy enforced on demo namespace
- **Security Contexts**: All workloads run as non-root with dropped capabilities
- **Firewall**: Explicit allow-list for all ports (no "any" rules)
- **RBAC**: Minimal permissions for cluster autoscaler
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
brew install terraform kubectl helm wireproxy packer jq  # macOS
# pacman -S terraform kubectl helm packer jq && go install github.com/pufferffish/wireproxy/cmd/wireproxy@latest  # Arch

# Create WireGuard keys (server + client)
mkdir -p ~/.wireguard
wg genkey | tee ~/.wireguard/hetzner-server-private | wg pubkey > ~/.wireguard/hetzner-server-public
wg genkey | tee ~/.wireguard/hetzner-client-private | wg pubkey > ~/.wireguard/hetzner-client-public

# Create Hetzner Cloud project + API token
# → https://console.hetzner.cloud → New Project → API Tokens → Generate (Read/Write)
```

### 2. Configure

```bash
cat > terraform.tfvars << 'EOF'
hcloud_token = "your-token-here"
EOF
```

### 3. Build Talos Image

Build the Talos snapshot once (or when upgrading Talos versions):

```bash
cd packer
packer init .
packer build -var "hcloud_token=$(grep -oP 'hcloud_token\s*=\s*"\K[^"]+' ../terraform.tfvars)" .
cd ..
```

### 4. Deploy Infrastructure

Terraform provisions servers, network, load balancer, firewall, bootstraps Talos, and starts a wireproxy tunnel.

```bash
export TF_VAR_wireguard_server_private_key="$(cat ~/.wireguard/hetzner-server-private)"
export TF_VAR_wireguard_server_public_key="$(cat ~/.wireguard/hetzner-server-public)"
export TF_VAR_wireguard_client_public_key="$(cat ~/.wireguard/hetzner-client-public)"
export TF_VAR_wireguard_client_private_key="$(cat ~/.wireguard/hetzner-client-private)"

terraform init
terraform plan
terraform apply
```

Terraform writes `.wireproxy.conf` in the project root and starts wireproxy in the background (PID in `.wireproxy.pid`). It creates TCP tunnels from `127.0.0.1:6443` (K8s API) and `127.0.0.1:50000` (Talos API) over WireGuard. On `terraform destroy`, the process is stopped and config files cleaned up automatically.

### 5. Configure Kubernetes Workloads

The post-deploy script installs Cilium (CNI), Hetzner CCM/CSI, Traefik, cert-manager, and the cluster autoscaler:

```bash
./scripts/post-deploy.sh              # interactive (prompts for monitoring)
./scripts/post-deploy.sh --monitoring  # include monitoring stack
./scripts/post-deploy.sh --no-monitoring
```

This automatically saves the kubeconfig to `.kubeconfig` in the project root.

### 6. DNS Setup

After deploy, add these records in Cloudflare (DNS-only mode, gray cloud):

| Type | Name | Value |
|------|------|-------|
| A | `*.k8s` | `<LB_IP from terraform output>` |
| A | `k8s` | `<LB_IP from terraform output>` |

### 7. Test

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
├── main.tf                         # Servers, network, firewall, LB, wireproxy
├── talos.tf                        # Talos secrets, machine configs, bootstrap, kubeconfig
├── variables.tf                    # Input variables with validation
├── outputs.tf                      # IPs, kubeconfig, talosconfig, autoscaler values
├── packer/
│   └── hcloud.pkr.hcl             # Build Talos image snapshot on Hetzner
├── scripts/
│   └── post-deploy.sh              # Installs Cilium, CCM, CSI, Traefik, cert-manager, autoscaler
├── manifests/
│   ├── traefik-values.yaml         # Traefik Helm values (proxy protocol for Hetzner LB)
│   ├── cert-manager-issuer.yaml    # Let's Encrypt ClusterIssuer
│   ├── cluster-autoscaler.yaml     # Autoscaler namespace, RBAC, deployment
│   ├── monitoring-values.yaml      # Helm values for kube-prometheus-stack
│   └── example-app.yaml            # Test deployment with security best practices
├── terraform.tfvars                # API token + overrides (not in git)
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
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: traefik
  tls:
    - hosts: ["myapp.k8s.simon-frey.com"]
      secretName: myapp-tls
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

```bash
# Via post-deploy script
./scripts/post-deploy.sh --monitoring

# Or manually with Helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f manifests/monitoring-values.yaml
```

Access Grafana via port-forward:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

## Operations

```bash
# View cluster nodes
kubectl get nodes -o wide

# View autoscaler logs
kubectl -n cluster-autoscaler logs -f deployment/cluster-autoscaler

# Stop wireproxy tunnel
kill $(cat .wireproxy.pid) 2>/dev/null

# Destroy everything
terraform destroy
```

### Optional: talosctl for debugging

`talosctl` is not required for the deploy flow (everything goes through Terraform), but useful for debugging:

```bash
# Install talosctl
curl -sL https://talos.dev/install | sh

# Save talosctl config
terraform output -raw talosconfig > ~/.talos/config
chmod 600 ~/.talos/config

# Check node health (via WireGuard tunnel)
talosctl health --nodes 127.0.0.1

# View Talos logs
talosctl logs kubelet --nodes 127.0.0.1
talosctl dmesg --nodes 127.0.0.1

# Upgrade Talos (after building new image with Packer)
talosctl upgrade --image factory.talos.dev/installer/<schematic>:<version> --nodes 127.0.0.1
```

## Troubleshooting

| Issue | Check |
|-------|-------|
| Can't connect to API | Is wireproxy running? `ps -p $(cat .wireproxy.pid)` and check `.wireproxy.log` |
| Nodes NotReady | Has Cilium been installed? `kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-agent` |
| Workers not joining | Check autoscaler logs: `kubectl -n cluster-autoscaler logs deploy/cluster-autoscaler` |
| LB health checks failing | `kubectl get pods -n traefik` — is Traefik running? |
| Cert not issuing | `kubectl describe certificate -n <namespace>` and `kubectl logs -n cert-manager deploy/cert-manager` |
| Pods stuck Pending | `kubectl describe pod <pod>` — check resource constraints or cloud-provider taint |
| No real client IPs | Verify Traefik proxy protocol config in `manifests/traefik-values.yaml` |

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `hcloud_token` | Hetzner Cloud API token | (required) |
| `cluster_name` | Name prefix for resources | `hetzner-k8s` |
| `server_type` | Server type for nodes | `cx23` |
| `talos_version` | Talos Linux version | `v1.9.5` |
| `wireguard_server_private_key` | WireGuard server private key (sensitive) | (required) |
| `wireguard_server_public_key` | WireGuard server public key | (required) |
| `wireguard_client_public_key` | Your WireGuard public key | (required) |
| `wireguard_client_private_key` | Your WireGuard private key (sensitive) | (required) |
| `autoscaler_min_nodes` | Minimum workers | `0` |
| `autoscaler_max_nodes` | Maximum workers | `5` |

See `variables.tf` for all options.
