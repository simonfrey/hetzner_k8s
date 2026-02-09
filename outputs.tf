# ============================================================================
# Outputs
# ============================================================================

output "control_plane_public_ip" {
  description = "Public IPv4 of the control plane"
  value       = hcloud_server.control_plane.ipv4_address
}

output "control_plane_private_ip" {
  description = "Private IP of the control plane"
  value       = "10.0.1.1"
}

output "load_balancer_ip" {
  description = "Public IPv4 of the load balancer (use for DNS)"
  value       = hcloud_load_balancer.ingress.ipv4
}

output "worker_public_ips" {
  description = "Public IPs of initial worker nodes"
  value       = hcloud_server.worker[*].ipv4_address
}

# ============================================================================
# SSH Commands
# ============================================================================

output "ssh_command" {
  description = "SSH into control plane"
  value       = "ssh -i ~/.ssh/hetzner-k8s root@${hcloud_server.control_plane.ipv4_address}"
}

# ============================================================================
# Kubeconfig
# ============================================================================

output "kubeconfig" {
  description = "Kubeconfig for cluster access (save to ~/.kube/hetzner-k8s.yaml)"
  value       = data.external.kubeconfig.result.kubeconfig
  sensitive   = true
}

output "kubeconfig_command" {
  description = "Command to save and use kubeconfig"
  value       = <<-EOT
    # Save kubeconfig:
    terraform output -raw kubeconfig > ~/.kube/hetzner-k8s.yaml
    chmod 600 ~/.kube/hetzner-k8s.yaml

    # Use it:
    export KUBECONFIG=~/.kube/hetzner-k8s.yaml
    kubectl get nodes
  EOT
}

# ============================================================================
# Wireguard VPN Configuration
# ============================================================================

output "wireguard_client_config" {
  description = "Wireguard client configuration (save to /etc/wireguard/hetzner-k8s.conf)"
  sensitive   = true
  value = var.enable_wireguard && var.wireguard_client_public_key != "" ? join("\n", [
    "[Interface]",
    "# Replace YOUR_PRIVATE_KEY with your client's private key",
    "PrivateKey = YOUR_PRIVATE_KEY",
    "Address = ${var.wireguard_client_ip}/32",
    "DNS = 10.0.1.1",
    "",
    "[Peer]",
    "PublicKey = ${data.external.wireguard_server_pubkey[0].result.pubkey}",
    "Endpoint = ${hcloud_server.control_plane.ipv4_address}:51820",
    "AllowedIPs = 10.200.200.1/32, 10.0.0.0/16",
    "PersistentKeepalive = 25"
  ]) : "Wireguard not enabled or client public key not provided"
}

output "wireguard_setup_instructions" {
  description = "Instructions for setting up Wireguard VPN access"
  value = var.enable_wireguard ? join("\n", [
    "",
    "=== Wireguard VPN Setup ===",
    "",
    "1. Generate client keys (if not already done):",
    "   wg genkey | tee ~/.wireguard/hetzner-k8s-private | wg pubkey > ~/.wireguard/hetzner-k8s-public",
    "",
    "2. Re-run terraform with your public key:",
    "   export TF_VAR_wireguard_client_public_key=\"$(cat ~/.wireguard/hetzner-k8s-public)\"",
    "   terraform apply",
    "",
    "3. Save the client config:",
    "   terraform output -raw wireguard_client_config > /etc/wireguard/hetzner-k8s.conf",
    "   # Edit the file and replace YOUR_PRIVATE_KEY with: $(cat ~/.wireguard/hetzner-k8s-private)",
    "",
    "4. Connect:",
    "   sudo wg-quick up hetzner-k8s",
    "",
    "5. Test connection:",
    "   ping 10.200.200.1",
    "   kubectl get nodes",
    "",
    "NOTE: The K8s API (port 6443) is only accessible via Wireguard VPN!",
    ""
  ]) : "Wireguard not enabled"
}

# ============================================================================
# DNS Instructions
# ============================================================================

output "dns_instructions" {
  description = "Manual DNS setup in Cloudflare"
  value       = <<-EOT

    Add these A records in Cloudflare (DNS-only mode, gray cloud):

    | Type | Name   | Value          |
    |------|--------|----------------|
    | A    | *.k8s  | ${hcloud_load_balancer.ingress.ipv4} |
    | A    | k8s    | ${hcloud_load_balancer.ingress.ipv4} |

    This enables:
      - https://hello.k8s.simon-frey.com
      - https://app.k8s.simon-frey.com
      - etc.

  EOT
}

# ============================================================================
# Autoscaler Configuration (for cluster-autoscaler.yaml)
# ============================================================================

output "autoscaler_config" {
  description = "Values needed for cluster-autoscaler manifest"
  value       = <<-EOT

    Network ID: ${hcloud_network.cluster.id}
    SSH Key ID: ${hcloud_ssh_key.default.id}
    Firewall ID: ${hcloud_firewall.cluster.id}

    Worker locations: ${join(", ", var.worker_locations)}
    Server type: ${var.server_type}
    Min nodes: ${var.autoscaler_min_nodes}
    Max nodes: ${var.autoscaler_max_nodes}

  EOT
}

output "cluster_name" {
  description = "Name of the cluster (used for resource naming)"
  value       = var.cluster_name
}

output "hcloud_token" {
  description = "Hetzner Cloud API token (used by post-deploy.sh for autoscaler secret)"
  value       = var.hcloud_token
  sensitive   = true
}

output "worker_cloud_init_base64" {
  description = "Base64-encoded cloud-init for autoscaler"
  value       = base64encode(local.agent_cloud_init)
  sensitive   = true
}

# ============================================================================
# Quick Reference
# ============================================================================

output "summary" {
  description = "Deployment summary"
  value       = <<-EOT

    Hetzner K8s Cluster Deployed!
    =============================

    Control Plane: ${hcloud_server.control_plane.ipv4_address} (${var.control_plane_location})
    Load Balancer: ${hcloud_load_balancer.ingress.ipv4}
    Initial Workers: ${var.initial_worker_count}
    Wireguard VPN: ${var.enable_wireguard ? "Enabled (port 51820)" : "Disabled"}

    Next Steps:
    1. Run: ./scripts/post-deploy.sh
    2. Add DNS records (see dns_instructions output)
    3. Deploy test app: kubectl apply -f manifests/example-app.yaml

    Security Notes:
    - K8s API (6443) is ${var.enable_wireguard ? "accessible only via Wireguard VPN" : "publicly accessible (consider enabling Wireguard)"}
    - etcd encryption at rest: Enabled
    - kubeconfig permissions: 600 (owner only)

  EOT
}
