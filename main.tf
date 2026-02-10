# ============================================================================
# K8s on Hetzner Cloud — Talos Linux + Cloud LB + Multi-DC + Autoscaler
# ============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.49.0, < 2.0.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.7.0, < 1.0.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0, < 4.0.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

# ============================================================================
# Local values
# ============================================================================

locals {
  common_labels = {
    cluster     = var.cluster_name
    managed_by  = "terraform"
    environment = "production"
  }
}

# ============================================================================
# Talos Image (built by Packer, referenced by label)
# ============================================================================

data "hcloud_image" "talos" {
  with_selector     = "os=talos"
  most_recent       = true
  with_architecture = "x86"
}

# ============================================================================
# Network (spans eu-central zone: fsn1, nbg1, hel1)
# ============================================================================

resource "hcloud_network" "cluster" {
  name     = "${var.cluster_name}-network"
  ip_range = "10.0.0.0/16"

  labels = local.common_labels

  lifecycle {
    prevent_destroy = false
  }
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = "10.0.1.0/24"
}

# ============================================================================
# Firewall
# ============================================================================

resource "hcloud_firewall" "cluster" {
  name = "${var.cluster_name}-fw"

  labels = local.common_labels

  lifecycle {
    prevent_destroy = false
  }

  # ============================================================================
  # Ingress rules (public interface only — Hetzner FW does NOT filter
  # private network traffic, so internal/10.0.0.0 rules have no effect)
  # ============================================================================

  # HTTP/HTTPS (defense-in-depth: LB uses private IP, but keep as fallback)
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTP"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTPS"
  }

  # WireGuard VPN
  rule {
    direction   = "in"
    protocol    = "udp"
    port        = "51820"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "WireGuard VPN"
  }

  # ICMP (required for Path MTU Discovery)
  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "ICMP (PMTUD, ping)"
  }

  # ============================================================================
  # Egress rules (public interface only)
  # ============================================================================

  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "443"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "HTTPS outbound (registries, APIs)"
  }

  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "80"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "HTTP outbound"
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "53"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "DNS outbound"
  }

  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "53"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "DNS TCP outbound"
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "123"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "NTP outbound"
  }

  rule {
    direction       = "out"
    protocol        = "icmp"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "ICMP outbound (PMTUD)"
  }
}

# ============================================================================
# Control Plane Node
# ============================================================================

resource "hcloud_server" "control_plane" {
  name         = "${var.cluster_name}-cp-1"
  image        = data.hcloud_image.talos.id
  server_type  = var.server_type
  location     = var.control_plane_location
  firewall_ids = [hcloud_firewall.cluster.id]

  labels = merge(local.common_labels, {
    role = "control-plane"
  })

  lifecycle {
    prevent_destroy = false
    ignore_changes  = [user_data, image]
  }

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.0.1.1"
  }

  user_data = data.talos_machine_configuration.controlplane.machine_configuration

  depends_on = [hcloud_network_subnet.nodes]
}

# ============================================================================
# Initial Worker Nodes (optional, for testing without autoscaler)
# Distributed round-robin across worker_locations
# ============================================================================

resource "hcloud_server" "worker" {
  count        = var.initial_worker_count
  name         = "${var.cluster_name}-worker-${count.index + 1}"
  image        = data.hcloud_image.talos.id
  server_type  = var.server_type
  location     = var.worker_locations[count.index % length(var.worker_locations)]
  firewall_ids = [hcloud_firewall.cluster.id]

  labels = merge(local.common_labels, {
    role                = "worker"
    "hcloud/node-group" = "workers"
  })

  lifecycle {
    ignore_changes = [user_data, image]
  }

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.0.1.${count.index + 10}"
  }

  user_data = data.talos_machine_configuration.worker.machine_configuration

  depends_on = [hcloud_server.control_plane]
}

# ============================================================================
# Load Balancer (routes to all nodes)
# ============================================================================

resource "hcloud_load_balancer" "ingress" {
  name               = "${var.cluster_name}-lb"
  load_balancer_type = "lb11" # 25 targets, 5 certs
  location           = var.control_plane_location

  labels = local.common_labels

  lifecycle {
    prevent_destroy = false
    # CCM manages algorithm, targets, and services once it takes over the LB
    ignore_changes = [algorithm]
  }
}

resource "hcloud_load_balancer_network" "ingress" {
  load_balancer_id = hcloud_load_balancer.ingress.id
  network_id       = hcloud_network.cluster.id
  ip               = "10.0.1.254"
}

# NOTE: LB targets and services are managed by Hetzner CCM via the
# load-balancer.hetzner.cloud/name annotation on the Traefik Service.
# CCM configures proxy protocol, health checks, and target discovery automatically.

# ============================================================================
# WireGuard Tunnel (starts BEFORE bootstrap — WireGuard is up at Talos boot)
# ============================================================================

resource "null_resource" "wireguard_tunnel" {
  depends_on = [hcloud_server.control_plane]

  triggers = {
    server_pubkey = var.wireguard_server_public_key
    endpoint      = hcloud_server.control_plane.ipv4_address
    client_ip     = var.wireguard_client_ip
  }

  provisioner "local-exec" {
    command     = <<-EOF
      # Write wireproxy config (userspace WireGuard, no root needed)
      cat > .wireproxy.conf << WPEOF
      [Interface]
      Address = ${var.wireguard_client_ip}/32
      PrivateKey = ${var.wireguard_client_private_key}

      [Peer]
      PublicKey = ${var.wireguard_server_public_key}
      Endpoint = ${hcloud_server.control_plane.ipv4_address}:51820
      AllowedIPs = 10.200.200.0/24, 10.0.0.0/16
      PersistentKeepalive = 25

      [TCPClientTunnel]
      BindAddress = 127.0.0.1:50000
      Target = 10.200.200.1:50000

      [TCPClientTunnel]
      BindAddress = 127.0.0.1:6443
      Target = 10.200.200.1:6443
      WPEOF
      chmod 600 .wireproxy.conf

      # Kill existing wireproxy if running
      if [ -f .wireproxy.pid ]; then
        kill $(cat .wireproxy.pid) 2>/dev/null || true
        sleep 1
      fi

      # Start wireproxy in background
      nohup wireproxy -c .wireproxy.conf > .wireproxy.log 2>&1 &
      echo $! > .wireproxy.pid

      # Wait for Talos API to be reachable through tunnel (port 50000)
      echo "Waiting for wireproxy tunnel to Talos API..."
      for i in $(seq 1 60); do
        if bash -c "echo >/dev/tcp/127.0.0.1/50000" 2>/dev/null; then
          echo "Wireproxy tunnel established (Talos API reachable)"
          exit 0
        fi
        sleep 3
      done
      echo "ERROR: Wireproxy tunnel failed — check .wireproxy.log" >&2
      exit 1
    EOF
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    command     = <<-EOF
      if [ -f .wireproxy.pid ]; then
        kill $(cat .wireproxy.pid) 2>/dev/null || true
        rm -f .wireproxy.pid .wireproxy.conf .wireproxy.log
      fi
    EOF
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}
