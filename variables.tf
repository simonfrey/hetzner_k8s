# ============================================================================
# Variables
# ============================================================================

variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "hetzner-k8s"
}

variable "domain" {
  description = "Base domain for services (e.g., k8s.simon-frey.com)"
  type        = string
  default     = "k8s.simon-frey.com"
}

# ============================================================================
# Server Configuration
# ============================================================================

variable "server_type" {
  description = "Hetzner server type for all nodes"
  type        = string
  default     = "cx33" # 2 vCPU, 4GB RAM - €3.99/mo
}

variable "control_plane_location" {
  description = "Location for control plane node"
  type        = string
  default     = "nbg1"  # fsn1 often at capacity, nbg1 more reliable
}

variable "worker_locations" {
  description = "Locations for worker nodes (autoscaler distributes round-robin)"
  type        = list(string)
  default     = ["nbg1", "hel1"]  # cx33 only available in nbg1/hel1
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
}

variable "autoscaler_max_nodes" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 5
}

# ============================================================================
# Initial Worker Count (for manual scaling without autoscaler)
# ============================================================================

variable "initial_worker_count" {
  description = "Number of workers to create initially (0 if using autoscaler)"
  type        = number
  default     = 0
}
