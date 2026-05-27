#!/bin/bash
set -e

HOST_KEY_DIR="/home/claude/.ssh-host-keys"
HOST_KEY="${HOST_KEY_DIR}/ssh_host_ed25519_key"

# Ensure directory exists (volume mount replaces /home/claude contents)
mkdir -p "$HOST_KEY_DIR"

# Generate host key on first boot (persisted on PVC)
if [ ! -f "$HOST_KEY" ]; then
  echo "Generating SSH host key..."
  ssh-keygen -t ed25519 -f "$HOST_KEY" -N ""
fi

echo "Starting sshd on 127.0.0.1:2222..."
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
