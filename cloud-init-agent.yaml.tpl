#cloud-config

package_update: true
packages:
  - curl
  - open-iscsi
  - nfs-common
  - jq

write_files:
  # Worker-fetch SSH private key (used to grab join token from control plane)
  - path: /root/.ssh/worker_fetch
    permissions: "0600"
    content: |
      ${indent(6, worker_fetch_privkey)}

  - path: /root/.ssh/config
    permissions: "0600"
    content: |
      Host control-plane
        HostName ${control_plane_ip}
        User root
        IdentityFile /root/.ssh/worker_fetch
        StrictHostKeyChecking accept-new

runcmd:
  # Wait for private network and detect interface
  - |
    echo "Waiting for private network..."
    for i in $(seq 1 60); do
      PRIVATE_IFACE=$(ip -4 addr show | grep -B2 'inet 10\.' | grep -oP '^\d+: \K[^:]+' | head -1)
      if [ -n "$PRIVATE_IFACE" ]; then
        echo "Private network interface: $PRIVATE_IFACE"
        break
      fi
      sleep 2
    done
    if [ -z "$PRIVATE_IFACE" ]; then
      echo "ERROR: No private network interface found"
      exit 1
    fi

  # Wait for control plane k3s API to be reachable
  - |
    echo "Waiting for control plane API..."
    until curl -sk https://${control_plane_ip}:6443/ping 2>/dev/null; do
      echo "  ...not ready yet, retrying in 5s"
      sleep 5
    done
    echo "Control plane API is reachable"

  # Fetch join token from control plane via SSH
  - |
    echo "Fetching k3s join token..."
    for i in $(seq 1 60); do
      K3S_TOKEN=$(ssh -o ConnectTimeout=5 control-plane "cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null)
      if [ -n "$K3S_TOKEN" ]; then
        echo "Got token"
        break
      fi
      echo "  ...token not available yet, retrying in 5s"
      sleep 5
    done

    if [ -z "$K3S_TOKEN" ]; then
      echo "ERROR: Failed to fetch k3s token after 5 minutes"
      exit 1
    fi

  # Get this node's private IP
  - |
    NODE_IP=$(ip -4 addr show $PRIVATE_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    echo "Node IP: $NODE_IP"

  # Install k3s agent
  - |
    curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="${k3s_channel}" sh -s - agent \
      --server=https://${control_plane_ip}:6443 \
      --token="$K3S_TOKEN" \
      --kubelet-arg="cloud-provider=external" \
      --flannel-iface=$PRIVATE_IFACE \
      --node-ip=$NODE_IP

  # Clean up the fetch key — no longer needed
  - rm -f /root/.ssh/worker_fetch /root/.ssh/config

  - echo "WORKER_READY" > /tmp/worker-ready
