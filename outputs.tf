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
# Kubeconfig (from Talos provider)
# ============================================================================

output "kubeconfig" {
  description = "Kubeconfig for cluster access (save to ~/.kube/hetzner-k8s.yaml)"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
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
# Talos Configuration
# ============================================================================

output "talosconfig" {
  description = "Talos client configuration for talosctl"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
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

    Point your wildcard domain to the LB IP for ingress routing.

  EOT
}

# ============================================================================
# Autoscaler Configuration
# ============================================================================

output "cluster_name" {
  description = "Name of the cluster (used for resource naming)"
  value       = var.cluster_name
}

output "hcloud_token" {
  description = "Hetzner Cloud API token (used by post-deploy.sh for autoscaler secret)"
  value       = var.hcloud_token
  sensitive   = true
}

output "worker_machine_config_base64" {
  description = "Base64-encoded Talos worker machine config for autoscaler"
  value       = base64encode(data.talos_machine_configuration.worker.machine_configuration)
  sensitive   = true
}

output "talos_image_id" {
  description = "Hetzner snapshot ID of the Talos image"
  value       = data.hcloud_image.talos.id
}

output "letsencrypt_email" {
  description = "Email address for Let's Encrypt certificate registration"
  value       = var.letsencrypt_email
}

# ============================================================================
# Quick Reference
# ============================================================================

output "summary" {
  description = "Deployment summary"
  value       = <<-EOT

    Hetzner K8s Cluster (Talos Linux) Deployed!
    =============================================

    Control Plane: ${hcloud_server.control_plane.ipv4_address} (${var.control_plane_location})
    Load Balancer: ${hcloud_load_balancer.ingress.ipv4}
    Initial Workers: ${var.initial_worker_count}
    Talos Version: ${var.talos_version}

    Next Steps:
    1. Run: ./scripts/post-deploy.sh
    2. Add DNS records (see dns_instructions output)
    3. Deploy test app: kubectl apply -f manifests/example-app.yaml

    Security Notes:
    - K8s API (6443) accessible only via WireGuard VPN
    - Talos API (50000) accessible only via WireGuard VPN
    - No SSH — manage via talosctl through WireGuard tunnel

  EOT
}
