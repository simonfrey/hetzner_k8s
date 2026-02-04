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

output "kubeconfig_command" {
  description = "Fetch kubeconfig from control plane"
  value       = <<-EOT
    # Run this after cloud-init completes (~3-5 min):
    scp -i ~/.ssh/hetzner-k8s root@${hcloud_server.control_plane.ipv4_address}:/etc/rancher/k3s/k3s.yaml ~/.kube/hetzner-k8s.yaml

    # Update the server address:
    sed -i 's|127.0.0.1|${hcloud_server.control_plane.ipv4_address}|g' ~/.kube/hetzner-k8s.yaml

    # Use it:
    export KUBECONFIG=~/.kube/hetzner-k8s.yaml
    kubectl get nodes
  EOT
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

output "worker_cloud_init_base64" {
  description = "Base64-encoded cloud-init for autoscaler"
  value = base64encode(templatefile("${path.module}/cloud-init-agent.yaml.tpl", {
    control_plane_ip     = "10.0.1.1"
    k3s_channel          = var.k3s_channel
    worker_fetch_privkey = tls_private_key.worker_fetch.private_key_openssh
  }))
  sensitive = true
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

    Next Steps:
    1. Wait for cloud-init to complete (~3-5 min)
    2. Run: ./scripts/post-deploy.sh
    3. Add DNS records (see dns_instructions output)
    4. Deploy test app: kubectl apply -f manifests/example-app.yaml

  EOT
}
