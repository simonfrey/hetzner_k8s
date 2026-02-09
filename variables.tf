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
      "cx23", "cx42", "cx52",                       # Shared vCPU (Intel)
      "cpx11", "cpx21", "cpx31", "cpx41", "cpx51",          # Shared vCPU (AMD)
      "ccx13", "ccx23", "ccx23", "ccx43", "ccx53", "ccx63", # Dedicated vCPU
      "cx23"                                                # Legacy type for backwards compatibility
    ], var.server_type)
    error_message = "server_type must be a valid Hetzner Cloud server type."
  }
}

variable "control_plane_location" {
  description = "Location for control plane node"
  type        = string
  default     = "nbg1" # fsn1 often at capacity, nbg1 more reliable
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
# SSH Configuration
# ============================================================================

variable "ssh_public_key_path" {
  description = "Path to SSH public key for node access"
  type        = string
  default     = "~/.ssh/hetzner-k8s.pub"
}

# ============================================================================
# Wireguard VPN Configuration
# ============================================================================

variable "wireguard_client_public_key" {
  description = "Public key of the Wireguard client that will access the K8s API. Generate with: wg genkey | tee privatekey | wg pubkey > publickey"
  type        = string
  default     = ""

  validation {
    condition     = var.wireguard_client_public_key == "" || can(regex("^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$", var.wireguard_client_public_key))
    error_message = "wireguard_client_public_key must be a valid WireGuard public key (44 chars, base64)."
  }
}

variable "wireguard_client_private_key" {
  description = "Private key of the WireGuard client. Required when enable_wireguard=true for automated tunnel setup. Generate with: wg genkey"
  type        = string
  default     = ""
  sensitive   = true
}

variable "wireguard_client_ip" {
  description = "IP address to assign to the Wireguard client within the VPN subnet"
  type        = string
  default     = "10.200.200.2"

  validation {
    condition     = can(cidrhost("10.200.200.0/24", tonumber(split(".", var.wireguard_client_ip)[3])))
    error_message = "wireguard_client_ip must be within 10.200.200.0/24 subnet."
  }
}

# ============================================================================
# K3s Configuration
# ============================================================================

variable "k3s_channel" {
  description = "K3s release channel (stable, latest, or specific version)"
  type        = string
  default     = "stable"
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
# Initial Worker Count (for manual scaling without autoscaler)
# ============================================================================

variable "initial_worker_count" {
  description = "Number of workers to create initially (0 if using autoscaler)"
  type        = number
  default     = 0
}

# ============================================================================
# Feature Flags
# ============================================================================

variable "enable_wireguard" {
  description = "Enable Wireguard VPN for secure K8s API access (requires wireguard_client_public_key)"
  type        = bool
  default     = true
}
