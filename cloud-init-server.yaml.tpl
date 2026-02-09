#cloud-config

package_update: true
packages:
  - curl
  - open-iscsi   # Required for Hetzner CSI
  - nfs-common   # Required for some CSI drivers
  - jq
%{ if enable_wireguard ~}
  - wireguard-tools
%{ endif ~}

# Add the worker-fetch SSH public key so workers can grab the join token
ssh_authorized_keys:
  - ${worker_fetch_pubkey}

write_files:
  # Hetzner Cloud secret for CCM + CSI (created before k3s starts manifests)
  - path: /var/lib/rancher/k3s/server/manifests/hcloud-secret.yaml
    permissions: "0600"
    content: |
      apiVersion: v1
      kind: Secret
      metadata:
        name: hcloud
        namespace: kube-system
      stringData:
        token: "${hcloud_token}"
        network: "${network_name}"

  # Hetzner Cloud Controller Manager (handles node lifecycle, LB integration)
  - path: /var/lib/rancher/k3s/server/manifests/hcloud-ccm.yaml
    permissions: "0644"
    content: |
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: hcloud-ccm
        namespace: kube-system
      spec:
        chart: hcloud-cloud-controller-manager
        repo: https://charts.hetzner.cloud
        targetNamespace: kube-system
        valuesContent: |-
          networking:
            enabled: true
          env:
            HCLOUD_TOKEN:
              valueFrom:
                secretKeyRef:
                  name: hcloud
                  key: token
            HCLOUD_NETWORK:
              valueFrom:
                secretKeyRef:
                  name: hcloud
                  key: network

  # Hetzner CSI Driver (persistent volumes via Hetzner block storage)
  - path: /var/lib/rancher/k3s/server/manifests/hcloud-csi.yaml
    permissions: "0644"
    content: |
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: hcloud-csi
        namespace: kube-system
      spec:
        chart: hcloud-csi
        repo: https://charts.hetzner.cloud
        targetNamespace: kube-system
        valuesContent: |-
          storageClasses:
            - name: hcloud-volumes
              defaultStorageClass: true
              reclaimPolicy: Retain

  # etcd encryption configuration
  - path: /var/lib/rancher/k3s/server/encryption-config.yaml
    permissions: "0600"
    content: |
      apiVersion: apiserver.config.k8s.io/v1
      kind: EncryptionConfiguration
      resources:
        - resources:
            - secrets
          providers:
            - aescbc:
                keys:
                  - name: key1
                    secret: ${etcd_encryption_key}
            - identity: {}

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

  # Get public and private IPs
  - |
    PUBLIC_IP=$(curl -s http://169.254.169.254/hetzner/v1/metadata/public-ipv4)
    PRIVATE_IP=$(ip -4 addr show "$PRIVATE_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    echo "Public IP: $PUBLIC_IP"
    echo "Private IP: $PRIVATE_IP"

%{ if enable_wireguard ~}
  # Enable IP forwarding for Wireguard
  - |
    echo "Enabling IP forwarding..."
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    sysctl -p

  # Generate Wireguard config
  - |
    cat > /etc/wireguard/wg0.conf << 'WGEOF'
    [Interface]
    Address = 10.200.200.1/24
    ListenPort = 51820
    PrivateKey = ${wireguard_server_privkey}
    PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

%{ if wireguard_client_pubkey != "" ~}
    [Peer]
    PublicKey = ${wireguard_client_pubkey}
    AllowedIPs = ${wireguard_client_ip}/32
%{ endif ~}
    WGEOF
    chmod 600 /etc/wireguard/wg0.conf
    echo "${wireguard_server_privkey}" | wg pubkey > /etc/wireguard/server.pub

  # Start Wireguard
  - |
    echo "Starting Wireguard..."
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
    wg show
%{ endif ~}

  # Install k3s server (control plane runs workloads - no taint initially)
  # NOTE: We intentionally omit --kubelet-arg="cloud-provider=external" on the control plane.
  # This prevents the node.cloudprovider.kubernetes.io/uninitialized taint that would block
  # the CCM helm-install job from scheduling, creating a deadlock where CCM can't install
  # to remove the taint. Workers still use external cloud provider for proper CCM integration.
  - |
    if ! curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="${k3s_channel}" sh -s - server \
      --disable-cloud-controller \
      --flannel-iface="$PRIVATE_IFACE" \
      --node-ip="$PRIVATE_IP" \
      --advertise-address="$PRIVATE_IP" \
      --tls-san="$PUBLIC_IP" \
      --tls-san="$PRIVATE_IP" \
      --tls-san="10.200.200.1" \
      --write-kubeconfig-mode=600 \
      --secrets-encryption; then
      echo "ERROR: k3s installation failed" >&2
      exit 1
    fi

  # Wait for k3s to be ready
  - |
    echo "Waiting for k3s to start..."
    TIMEOUT=300; ELAPSED=0
    until kubectl get nodes --kubeconfig /etc/rancher/k3s/k3s.yaml 2>/dev/null; do
      sleep 3; ELAPSED=$((ELAPSED+3))
      if [ $ELAPSED -ge $TIMEOUT ]; then echo "TIMEOUT waiting for k3s in cloud-init" >&2; exit 1; fi
    done
    echo "k3s control plane is ready"

  # Taint control plane node (workloads should run on workers when available)
  - |
    echo "Tainting control plane node..."
    kubectl taint nodes "$(hostname)" node-role.kubernetes.io/control-plane=:NoSchedule --kubeconfig /etc/rancher/k3s/k3s.yaml --overwrite || true

  # Signal readiness (token is now available for workers)
  - echo "CONTROL_PLANE_READY" > /tmp/cp-ready
