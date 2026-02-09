# ============================================================================
# Talos Linux: Secrets, Machine Configs, Bootstrap, Kubeconfig
# ============================================================================

# ============================================================================
# 1. Machine Secrets (cluster encryption/auth — replaces random_password, tls_private_key)
# ============================================================================

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# ============================================================================
# 2. Client Configuration (talosctl config)
# ============================================================================

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = ["127.0.0.1"]
  nodes                = ["127.0.0.1"]
}

# ============================================================================
# 3. Control Plane Machine Configuration
# ============================================================================

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = "https://10.0.1.1:6443"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = [
    yamlencode({
      machine = {
        # WireGuard interface
        network = {
          interfaces = [
            {
              interface = "wg0"
              mtu       = 1420
              addresses = ["10.200.200.1/24"]
              wireguard = {
                privateKey = var.wireguard_server_private_key
                listenPort = 51820
                peers = [
                  {
                    publicKey  = var.wireguard_client_public_key
                    allowedIPs = ["${var.wireguard_client_ip}/32"]
                  }
                ]
              }
            }
          ]
        }
        # Hetzner NTP servers
        time = {
          servers = [
            "ntp1.hetzner.de"
            , "ntp2.hetzner.com"
            , "ntp3.hetzner.net"
          ]
        }
        # certSANs for API access via WireGuard and internal
        certSANs = [
          "10.0.1.1"
          , "10.200.200.1"
          , "127.0.0.1"
        ]
      }
      cluster = {
        # No built-in CNI — Cilium installed via post-deploy
        network = {
          cni = {
            name = "none"
          }
        }
        # Cilium replaces kube-proxy
        proxy = {
          disabled = true
        }
        # External cloud provider (Hetzner CCM)
        externalCloudProvider = {
          enabled = true
        }
        # Allow workloads on control plane (workers can scale to 0)
        allowSchedulingOnControlPlanes = true
        # Advertise etcd on private network
        etcd = {
          advertisedSubnets = ["10.0.1.0/24"]
        }
        # Inline manifest: hcloud secret for CCM/CSI
        inlineManifests = [
          {
            name = "hcloud-secret"
            contents = yamlencode({
              apiVersion = "v1"
              kind       = "Secret"
              metadata = {
                name      = "hcloud"
                namespace = "kube-system"
              }
              stringData = {
                token   = var.hcloud_token
                network = "${var.cluster_name}-network"
              }
            })
          }
        ]
      }
    })
  ]
}

# ============================================================================
# 4. Worker Machine Configuration
# ============================================================================

data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  machine_type     = "worker"
  cluster_endpoint = "https://10.0.1.1:6443"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = [
    yamlencode({
      machine = {
        time = {
          servers = [
            "ntp1.hetzner.de"
            , "ntp2.hetzner.com"
            , "ntp3.hetzner.net"
          ]
        }
      }
      cluster = {
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
        }
        externalCloudProvider = {
          enabled = true
        }
      }
    })
  ]
}

# ============================================================================
# 5. Bootstrap (initializes etcd — via WireGuard tunnel)
# ============================================================================

resource "talos_machine_bootstrap" "this" {
  depends_on = [null_resource.wireguard_tunnel]

  node                 = "127.0.0.1"
  endpoint             = "127.0.0.1"
  client_configuration = talos_machine_secrets.this.client_configuration

  timeouts = {
    create = "10m"
  }
}

# ============================================================================
# 6. Cluster Kubeconfig (via WireGuard tunnel)
# ============================================================================

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  node                 = "127.0.0.1"
  endpoint             = "127.0.0.1"
  client_configuration = talos_machine_secrets.this.client_configuration

  timeouts = {
    read = "10m"
  }
}
