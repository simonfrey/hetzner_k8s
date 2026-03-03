# ============================================================================
# Variables
# ============================================================================

variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.hcloud_token) >= 64
    error_message = "hcloud_token must be at least 64 characters (Hetzner API tokens are 64 chars)."
  }
}

variable "cluster_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "hetzner-k8s"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric with hyphens, start with letter, end with alphanumeric, max 40 chars."
  }
}

# ============================================================================
# Server Configuration
# ============================================================================

variable "server_type" {
  description = "Hetzner server type for all nodes"
  type        = string
  default     = "cx23" # 2 vCPU, 4GB RAM

  validation {
    condition = contains([
      "cx23", "cx33", "cx43", "cx53",                       # Shared vCPU (Intel)
      "cpx11", "cpx21", "cpx31", "cpx41", "cpx51",          # Shared vCPU (AMD)
      "ccx13", "ccx23", "ccx33", "ccx43", "ccx53", "ccx63", # Dedicated vCPU
    ], var.server_type)
    error_message = "server_type must be a valid Hetzner Cloud server type."
  }
}

variable "control_plane_location" {
  description = "Location for control plane node"
  type        = string
  default     = "nbg1"
}

variable "worker_locations" {
  description = "Locations for worker nodes (autoscaler distributes round-robin)"
  type        = list(string)
  default     = ["nbg1", "hel1"]
}

variable "network_zone" {
  description = "Network zone for private network (eu-central covers fsn1, nbg1, hel1)"
  type        = string
  default     = "eu-central"
}

# ============================================================================
# Talos Configuration
# ============================================================================

variable "talos_version" {
  description = "Talos Linux version (must match the Packer-built image)"
  type        = string
  default     = "v1.12.0"
}

# ============================================================================
# WireGuard VPN Configuration
# ============================================================================

variable "wireguard_server_private_key" {
  description = "WireGuard server private key. Generate with: wg genkey"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$", var.wireguard_server_private_key))
    error_message = "wireguard_server_private_key must be a valid WireGuard private key (44 chars, base64)."
  }
}

variable "wireguard_server_public_key" {
  description = "WireGuard server public key (derived from server private key). Generate with: echo '<private_key>' | wg pubkey"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$", var.wireguard_server_public_key))
    error_message = "wireguard_server_public_key must be a valid WireGuard public key (44 chars, base64)."
  }
}

variable "wireguard_client_public_key" {
  description = "Public key of the WireGuard client that will access the K8s API. Generate with: wg genkey | tee privatekey | wg pubkey > publickey"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$", var.wireguard_client_public_key))
    error_message = "wireguard_client_public_key must be a valid WireGuard public key (44 chars, base64)."
  }
}

variable "wireguard_client_private_key" {
  description = "Private key of the WireGuard client. Required for automated tunnel setup. Generate with: wg genkey"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$", var.wireguard_client_private_key))
    error_message = "wireguard_client_private_key must be a valid WireGuard private key (44 chars, base64)."
  }
}

variable "wireguard_client_ip" {
  description = "IP address to assign to the WireGuard client within the VPN subnet"
  type        = string
  default     = "10.200.200.2"

  validation {
    condition     = can(cidrhost("10.200.200.0/24", tonumber(split(".", var.wireguard_client_ip)[3])))
    error_message = "wireguard_client_ip must be within 10.200.200.0/24 subnet."
  }
}

# ============================================================================
# Autoscaler Configuration
# ============================================================================

variable "autoscaler_min_nodes" {
  description = "Minimum number of worker nodes (can be 0)"
  type        = number
  default     = 0

  validation {
    condition     = var.autoscaler_min_nodes >= 0
    error_message = "autoscaler_min_nodes must be >= 0."
  }
}

variable "autoscaler_max_nodes" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 5

  validation {
    condition     = var.autoscaler_max_nodes >= 1 && var.autoscaler_max_nodes <= 100
    error_message = "autoscaler_max_nodes must be between 1 and 100."
  }
}

# ============================================================================
# Let's Encrypt Configuration
# ============================================================================

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt certificate registration"
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.letsencrypt_email))
    error_message = "letsencrypt_email must be a valid email address."
  }
}

# ============================================================================
# Initial Worker Count (for manual scaling without autoscaler)
# ============================================================================

variable "initial_worker_count" {
  description = "Number of workers to create initially (0 if using autoscaler)"
  type        = number
  default     = 0
}

# ============================================================================
# KubeVirt Configuration
# ============================================================================

variable "kubevirt_server_type" {
  description = "Hetzner server type for KubeVirt node (must be CCX for nested virtualization)"
  type        = string
  default     = "ccx23" # 4 dedicated vCPU (AMD EPYC), 16GB RAM

  validation {
    condition = contains([
      "ccx13", "ccx23", "ccx33", "ccx43", "ccx53", "ccx63",
    ], var.kubevirt_server_type)
    error_message = "kubevirt_server_type must be a dedicated vCPU (CCX) Hetzner server type for nested virtualization."
  }
}

# ============================================================================
# GitOps / ArgoCD Configuration
# ============================================================================

variable "git_repo_url" {
  description = "Git repository URL for ArgoCD to sync from"
  type        = string
  default     = "https://github.com/simonfrey/hetzner_k8s.git"
}

variable "git_target_revision" {
  description = "Git branch/tag/commit for ArgoCD to track"
  type        = string
  default     = "main"
}

variable "enable_monitoring" {
  description = "Deploy kube-Okay Oprometheus-stack via ArgoCD"
  type        = bool
  default     = false
}

variable "enable_windows_vm" {
  description = "Deploy Windows VM + Guacamole via ArgoCD"
  type        = bool
  default     = false
}
