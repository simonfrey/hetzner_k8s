#cloud-config

package_update: true
packages:
  - curl
  - open-iscsi   # Required for Hetzner CSI
  - nfs-common   # Required for some CSI drivers
  - jq

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
              reclaimPolicy: Delete

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
    PRIVATE_IP=$(ip -4 addr show $PRIVATE_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    echo "Public IP: $PUBLIC_IP"
    echo "Private IP: $PRIVATE_IP"

  # Install k3s server (control plane runs workloads - no taint)
  # NOTE: We intentionally omit --kubelet-arg="cloud-provider=external" on the control plane.
  # This prevents the node.cloudprovider.kubernetes.io/uninitialized taint that would block
  # the CCM helm-install job from scheduling, creating a deadlock where CCM can't install
  # to remove the taint. Workers still use external cloud provider for proper CCM integration.
  - |
    curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="${k3s_channel}" sh -s - server \
      --disable-cloud-controller \
      --flannel-iface=$PRIVATE_IFACE \
      --node-ip=$PRIVATE_IP \
      --advertise-address=$PRIVATE_IP \
      --tls-san=$PUBLIC_IP \
      --tls-san=$PRIVATE_IP \
      --write-kubeconfig-mode=644

  # Wait for k3s to be ready
  - |
    echo "Waiting for k3s to start..."
    until kubectl get nodes --kubeconfig /etc/rancher/k3s/k3s.yaml 2>/dev/null; do
      sleep 3
    done
    echo "k3s control plane is ready"

  # Signal readiness (token is now available for workers)
  - echo "CONTROL_PLANE_READY" > /tmp/cp-ready
