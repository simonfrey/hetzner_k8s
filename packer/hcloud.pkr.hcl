# ============================================================================
# Packer: Build Talos Linux image snapshot on Hetzner Cloud
# ============================================================================
#
# Usage:
#   cd packer
#   packer init .
#   packer build -var "hcloud_token=$(grep -oP 'hcloud_token\s*=\s*"\K[^"]+' ../terraform.tfvars)" .
#
# The resulting snapshot is referenced in Terraform via:
#   data "hcloud_image" "talos" { with_selector = "os=talos" }
#
# Rebuild when upgrading Talos versions.
# ============================================================================

packer {
  required_plugins {
    hcloud = {
      source  = "github.com/hetznercloud/hcloud"
      version = ">= 1.6.0"
    }
  }
}

variable "talos_version" {
  type    = string
  default = "v1.12.0"
}

# Talos factory image schematic with qemu-guest-agent extension (required for Hetzner)
# Generated at https://factory.talos.dev/ with extensions: siderolabs/qemu-guest-agent
variable "talos_schematic_id" {
  type    = string
  default = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
}

variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token. Pass via: -var \"hcloud_token=...\""
}

variable "server_type" {
  type    = string
  default = "cx23"
}

variable "server_location" {
  type    = string
  default = "nbg1"
}

source "hcloud" "talos" {
  token       = var.hcloud_token
  location    = var.server_location
  server_type = var.server_type
  server_name = "packer-talos-builder"

  # Boot into Hetzner rescue mode (Linux environment for dd)
  rescue = "linux64"

  # Use any base image (doesn't matter, we boot into rescue)
  image = "ubuntu-24.04"

  snapshot_name = "talos-${var.talos_version}"
  snapshot_labels = {
    os      = "talos"
    version = var.talos_version
  }

  ssh_username = "root"
}

build {
  sources = ["source.hcloud.talos"]

  # Download Talos factory image and write to disk
  provisioner "shell" {
    inline = [
      "set -ex",

      # Download the Talos raw image from factory
      "wget -O /tmp/talos.raw.xz https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/hcloud-amd64.raw.xz",

      # Write image to disk
      "xz -d -c /tmp/talos.raw.xz | dd of=/dev/sda bs=4M status=progress",

      # Ensure all writes are flushed
      "sync",

      # Clean up
      "rm -f /tmp/talos.raw.xz",
    ]
  }
}
