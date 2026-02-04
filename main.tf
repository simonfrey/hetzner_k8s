# ============================================================================
# K8s on Hetzner Cloud — k3s + Cloud LB + Multi-DC + Autoscaler
# ============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

# ============================================================================
# SSH Key
# ============================================================================

resource "hcloud_ssh_key" "default" {
  name       = "${var.cluster_name}-key"
  public_key = file(var.ssh_public_key_path)
}

# Generate a dedicated key pair for worker→control-plane token fetch
resource "tls_private_key" "worker_fetch" {
  algorithm = "ED25519"
}

# ============================================================================
# Network (spans eu-central zone: fsn1, nbg1, hel1)
# ============================================================================

resource "hcloud_network" "cluster" {
  name     = "${var.cluster_name}-network"
  ip_range = "10.0.0.0/16"
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

  # SSH
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "SSH"
  }

  # HTTP (via LB)
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTP"
  }

  # HTTPS
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTPS"
  }

  # k3s API — restrict to your IP in production
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "6443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Kubernetes API"
  }

  # Allow all traffic within private network (node-to-node)
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "any"
    source_ips  = ["10.0.0.0/16"]
    description = "Internal cluster traffic"
  }

  rule {
    direction   = "in"
    protocol    = "udp"
    port        = "any"
    source_ips  = ["10.0.0.0/16"]
    description = "Internal cluster traffic UDP"
  }
}

# ============================================================================
# Control Plane Node (always on, in fsn1)
# ============================================================================

resource "hcloud_server" "control_plane" {
  name         = "${var.cluster_name}-cp-1"
  image        = "ubuntu-24.04"
  server_type  = var.server_type
  location     = var.control_plane_location
  ssh_keys     = [hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.cluster.id]

  labels = {
    role    = "control-plane"
    cluster = var.cluster_name
  }

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.0.1.1"
  }

  user_data = templatefile("${path.module}/cloud-init-server.yaml.tpl", {
    hcloud_token        = var.hcloud_token
    cluster_name        = var.cluster_name
    network_name        = hcloud_network.cluster.name
    k3s_channel         = var.k3s_channel
    worker_fetch_pubkey = tls_private_key.worker_fetch.public_key_openssh
  })

  depends_on = [hcloud_network_subnet.nodes]
}

# ============================================================================
# Initial Worker Nodes (optional, for testing without autoscaler)
# Distributed round-robin across worker_locations
# ============================================================================

resource "hcloud_server" "worker" {
  count        = var.initial_worker_count
  name         = "${var.cluster_name}-worker-${count.index + 1}"
  image        = "ubuntu-24.04"
  server_type  = var.server_type
  location     = var.worker_locations[count.index % length(var.worker_locations)]
  ssh_keys     = [hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.cluster.id]

  labels = {
    role    = "worker"
    cluster = var.cluster_name
    # Label for autoscaler node pool identification
    "hcloud/node-group" = "workers"
  }

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.0.1.${count.index + 10}"
  }

  user_data = templatefile("${path.module}/cloud-init-agent.yaml.tpl", {
    control_plane_ip     = "10.0.1.1"
    k3s_channel          = var.k3s_channel
    worker_fetch_privkey = tls_private_key.worker_fetch.private_key_openssh
  })

  depends_on = [hcloud_server.control_plane]
}

# ============================================================================
# Load Balancer (in fsn1, routes to all nodes)
# ============================================================================

resource "hcloud_load_balancer" "ingress" {
  name               = "${var.cluster_name}-lb"
  load_balancer_type = "lb11" # 25 targets, 5 certs, €5.39/mo
  location           = var.control_plane_location

  labels = {
    cluster = var.cluster_name
  }
}

resource "hcloud_load_balancer_network" "ingress" {
  load_balancer_id = hcloud_load_balancer.ingress.id
  network_id       = hcloud_network.cluster.id
  ip               = "10.0.1.254"
}

# Control plane is always a target (runs workloads since workers can scale to 0)
resource "hcloud_load_balancer_target" "control_plane" {
  type             = "server"
  load_balancer_id = hcloud_load_balancer.ingress.id
  server_id        = hcloud_server.control_plane.id
  use_private_ip   = true
  depends_on       = [hcloud_load_balancer_network.ingress]
}

# Initial workers as LB targets
resource "hcloud_load_balancer_target" "workers" {
  count            = var.initial_worker_count
  type             = "server"
  load_balancer_id = hcloud_load_balancer.ingress.id
  server_id        = hcloud_server.worker[count.index].id
  use_private_ip   = true
  depends_on       = [hcloud_load_balancer_network.ingress]
}

# Label selector for autoscaled workers (CCM will add them automatically)
resource "hcloud_load_balancer_target" "label_selector" {
  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.ingress.id
  label_selector   = "cluster=${var.cluster_name},role=worker"
  use_private_ip   = true
  depends_on       = [hcloud_load_balancer_network.ingress]
}

# TCP passthrough — TLS terminates at Traefik, not the LB
resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.ingress.id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = 80
  proxyprotocol    = true

  health_check {
    protocol = "tcp"
    port     = 80
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "https" {
  load_balancer_id = hcloud_load_balancer.ingress.id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = 443
  proxyprotocol    = true

  health_check {
    protocol = "tcp"
    port     = 443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}
