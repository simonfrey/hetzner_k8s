# ============================================================================
# ArgoCD GitOps Bootstrap
# Installs Cilium (CNI) + ArgoCD + root Application + secrets/configmaps
# Everything else is managed by ArgoCD from gitops/ directory
# ============================================================================

# ============================================================================
# A) Wait for Kubernetes API to be ready
# After talos_machine_bootstrap, the API server is still initializing.
# Helm/Kubernetes providers will TLS-timeout if we don't wait.
# ============================================================================

resource "null_resource" "wait_for_k8s_api" {
  depends_on = [talos_cluster_kubeconfig.this]

  provisioner "local-exec" {
    command     = <<-EOF
      echo "Waiting for Kubernetes API to be ready..."
      for i in $(seq 1 60); do
        if curl -sk https://127.0.0.1:6443/version >/dev/null 2>&1; then
          echo "Kubernetes API is ready"
          exit 0
        fi
        sleep 5
      done
      echo "ERROR: Kubernetes API not ready after 5 minutes" >&2
      exit 1
    EOF
    interpreter = ["bash", "-c"]
  }
}

# ============================================================================
# B) Cilium CNI — nodes are NotReady without it, must be first
# ============================================================================

resource "helm_release" "cilium" {
  name             = "cilium"
  namespace        = "kube-system"
  repository       = "https://helm.cilium.io/"
  chart            = "cilium"
  version          = "1.19.0"
  create_namespace = false
  wait             = true
  timeout          = 600

  set {
    name  = "ipam.mode"
    value = "kubernetes"
  }
  set {
    name  = "k8sServiceHost"
    value = "localhost"
  }
  set {
    name  = "k8sServicePort"
    value = "7445"
  }
  set {
    name  = "kubeProxyReplacement"
    value = "true"
  }
  set {
    name  = "cgroup.autoMount.enabled"
    value = "false"
  }
  set {
    name  = "cgroup.hostRoot"
    value = "/sys/fs/cgroup"
  }
  set {
    name  = "securityContext.capabilities.ciliumAgent"
    value = "{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
  }
  set {
    name  = "securityContext.capabilities.cleanCiliumState"
    value = "{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
  }

  depends_on = [null_resource.wait_for_k8s_api]
}

# ============================================================================
# B2) Wait for CoreDNS — needed before any image pull from external registries
# Cilium provides pod networking, but CoreDNS pods may still be starting.
# Without DNS, pre-install hook Jobs fail with ImagePullBackOff.
# ============================================================================

resource "null_resource" "wait_for_coredns" {
  depends_on = [helm_release.cilium]

  provisioner "local-exec" {
    command     = <<-EOF
      TMPKUBECONFIG=$(mktemp)
      trap "rm -f $TMPKUBECONFIG" EXIT
      echo "$KUBECONFIG_RAW" > "$TMPKUBECONFIG"
      sed -i 's|server: https://10\.0\.1\.1:6443|server: https://127.0.0.1:6443|g' "$TMPKUBECONFIG"
      export KUBECONFIG="$TMPKUBECONFIG"

      echo "Waiting for CoreDNS to be ready..."
      for i in $(seq 1 60); do
        READY=$(kubectl get deploy coredns -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        if [ "$READY" != "" ] && [ "$READY" -ge 1 ] 2>/dev/null; then
          echo "CoreDNS is ready ($READY replicas)"
          exit 0
        fi
        echo "  CoreDNS not ready yet (attempt $i/60)..."
        sleep 5
      done
      echo "ERROR: CoreDNS not ready after 5 minutes" >&2
      exit 1
    EOF
    interpreter = ["bash", "-c"]
    environment = {
      KUBECONFIG_RAW = talos_cluster_kubeconfig.this.kubeconfig_raw
    }
  }
}

# ============================================================================
# C) ArgoCD — GitOps controller
# ============================================================================

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.8.13"
  create_namespace = true
  wait             = true
  timeout          = 600

  # Tolerations: ArgoCD must schedule before CCM initializes nodes
  # (cloud-provider taint) and on control-plane if workers scale to 0.
  values = [yamlencode({
    global = {
      tolerations = [
        {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        },
        {
          key      = "node.cloudprovider.kubernetes.io/uninitialized"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]
    }
  })]

  # Enable server-side diff globally — ArgoCD's built-in K8s schema
  # doesn't know about fields added in K8s 1.33+ (e.g. .status.terminatingReplicas),
  # causing ComparisonError on client-side diff.
  set {
    name  = "configs.params.controller\\.diff\\.server\\.side"
    value = "true"
  }

  # Server runs insecure (Traefik handles TLS if exposed)
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  # Disable unused components
  set {
    name  = "dex.enabled"
    value = "false"
  }
  set {
    name  = "notifications.enabled"
    value = "false"
  }

  depends_on = [null_resource.wait_for_coredns]
}

# ============================================================================
# C) Random passwords for Windows, Guacamole, Grafana
# ============================================================================

resource "random_password" "windows_admin" {
  length  = 16
  special = true
}

resource "random_password" "guacamole" {
  length  = 24
  special = true
}

resource "random_password" "grafana" {
  length  = 24
  special = true
}

# ============================================================================
# D) Namespaces and Secrets
# ============================================================================

# --- cluster-autoscaler ---

resource "kubernetes_namespace" "cluster_autoscaler" {
  metadata {
    name = "cluster-autoscaler"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }

  depends_on = [helm_release.cilium]
}

resource "kubernetes_secret" "hcloud_autoscaler" {
  metadata {
    name      = "hcloud-autoscaler"
    namespace = kubernetes_namespace.cluster_autoscaler.metadata[0].name
  }

  data = {
    token      = var.hcloud_token
    cloud-init = base64encode(data.talos_machine_configuration.worker.machine_configuration)
    network    = "${var.cluster_name}-network"
    firewall   = "${var.cluster_name}-fw"
    image      = data.hcloud_image.talos.id
  }
}

# --- windows ---

resource "kubernetes_namespace" "windows" {
  count = var.enable_windows_vm ? 1 : 0

  metadata {
    name = "windows"
    labels = {
      "pod-security.kubernetes.io/enforce"         = "privileged"
      "pod-security.kubernetes.io/enforce-version" = "latest"
    }
  }

  depends_on = [helm_release.cilium]
}

resource "kubernetes_secret" "windows_passwords" {
  count = var.enable_windows_vm ? 1 : 0

  metadata {
    name      = "windows-passwords"
    namespace = kubernetes_namespace.windows[0].metadata[0].name
  }

  data = {
    admin-password = random_password.windows_admin.result
    guac-password  = random_password.guacamole.result
  }
}

# Guacamole password SHA256 hash (needed in user-mapping.xml)
locals {
  guacamole_password_sha256 = sha256(random_password.guacamole.result)
}

resource "kubernetes_config_map" "windows_sysprep" {
  count = var.enable_windows_vm ? 1 : 0

  metadata {
    name      = "windows-sysprep"
    namespace = kubernetes_namespace.windows[0].metadata[0].name
  }

  data = {
    "autounattend.xml" = templatefile("${path.module}/templates/autounattend.xml.tftpl", {
      windows_admin_password = random_password.windows_admin.result
    })
  }
}

resource "kubernetes_config_map" "guacamole_config" {
  count = var.enable_windows_vm ? 1 : 0

  metadata {
    name      = "guacamole-config"
    namespace = kubernetes_namespace.windows[0].metadata[0].name
  }

  data = {
    "user-mapping.xml" = templatefile("${path.module}/templates/user-mapping.xml.tftpl", {
      guacamole_password_sha256 = local.guacamole_password_sha256
      windows_admin_password    = random_password.windows_admin.result
    })
  }
}

# --- kwatch ---

resource "kubernetes_namespace" "kwatch" {
  metadata {
    name = "kwatch"
    labels = {
      "argocd.argoproj.io/instance" = "kwatch"
    }
  }

  depends_on = [helm_release.cilium]
}

resource "kubernetes_config_map" "kwatch" {
  metadata {
    name      = "kwatch"
    namespace = kubernetes_namespace.kwatch.metadata[0].name
  }

  data = {
    "config.yaml" = yamlencode({
      maxRecentLogLines              = 20
      ignoreFailedGracefulShutdown   = true
      pvcMonitor = {
        enabled   = true
        interval  = 15
        threshold = 80
      }
      nodeMonitor = {
        enabled = true
      }
      alert = {
        webhook = {
          url = var.pushover_webhook_url
        }
      }
    })
  }
}

# --- monitoring ---

resource "kubernetes_namespace" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  metadata {
    name = "monitoring"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }

  depends_on = [helm_release.cilium]
}

resource "kubernetes_secret" "grafana_admin" {
  count = var.enable_monitoring ? 1 : 0

  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace.monitoring[0].metadata[0].name
  }

  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana.result
  }
}

resource "kubernetes_secret" "alertmanager_pushover" {
  count = var.enable_monitoring ? 1 : 0

  metadata {
    name      = "alertmanager-pushover"
    namespace = kubernetes_namespace.monitoring[0].metadata[0].name
  }

  data = {
    user-key  = var.pushover_user_key
    api-token = var.pushover_api_token
  }
}

# ============================================================================
# F) Root Application (app-of-apps entry point)
# Uses a local Helm chart instead of kubernetes_manifest because
# kubernetes_manifest connects to the API during plan (fails on fresh clusters).
# ============================================================================

resource "helm_release" "argocd_root_app" {
  name      = "root-app"
  namespace = "argocd"
  chart     = "${path.module}/gitops/bootstrap"
  wait      = false # ArgoCD Application is async — don't block on it

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "letsencryptEmail"
    value = var.letsencrypt_email
  }
  set {
    name  = "repoURL"
    value = var.git_repo_url
  }
  set {
    name  = "targetRevision"
    value = var.git_target_revision
  }
  set {
    name  = "enableMonitoring"
    value = tostring(var.enable_monitoring)
  }
  set {
    name  = "enableWindows"
    value = tostring(var.enable_windows_vm)
  }
  set {
    name  = "enableWebsite"
    value = tostring(var.enable_website)
  }

  depends_on = [helm_release.argocd]
}

# ============================================================================
# H) simon-frey.com website — SSH deploy key + secrets
# ============================================================================

# SSH keypair for ArgoCD to access the private simonfrey/simon-frey.com repo
resource "tls_private_key" "website_deploy_key" {
  count     = var.enable_website ? 1 : 0
  algorithm = "ED25519"
}

# ArgoCD repo credential — tells ArgoCD how to clone the private repo
resource "kubernetes_secret" "argocd_repo_website" {
  count = var.enable_website ? 1 : 0

  metadata {
    name      = "argocd-repo-simon-frey-com"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type          = "git"
    url           = "git@github.com:simonfrey/simon-frey.com.git"
    sshPrivateKey = tls_private_key.website_deploy_key[0].private_key_openssh
  }

  depends_on = [helm_release.argocd]
}

# --- simon-frey-com namespace and secrets ---

resource "kubernetes_namespace" "simon_frey_com" {
  count = var.enable_website ? 1 : 0

  metadata {
    name = "simon-frey-com"
  }

  depends_on = [helm_release.cilium]
}

# WordPress MySQL passwords
resource "random_password" "mysql_root" {
  count   = var.enable_website ? 1 : 0
  length  = 24
  special = false
}

resource "random_password" "wordpress_db" {
  count   = var.enable_website ? 1 : 0
  length  = 24
  special = false
}

resource "kubernetes_secret" "wordpress_db_credentials" {
  count = var.enable_website ? 1 : 0

  metadata {
    name      = "wordpress-db-credentials"
    namespace = kubernetes_namespace.simon_frey_com[0].metadata[0].name
  }

  data = {
    mysql-root-password = random_password.mysql_root[0].result
    mysql-password      = random_password.wordpress_db[0].result
    mysql-database      = "wordpress"
    mysql-user          = "wordpress"
  }
}

# MinIO credentials
resource "random_password" "minio_root" {
  count   = var.enable_website ? 1 : 0
  length  = 24
  special = false
}

resource "kubernetes_secret" "minio_credentials" {
  count = var.enable_website ? 1 : 0

  metadata {
    name      = "minio-credentials"
    namespace = kubernetes_namespace.simon_frey_com[0].metadata[0].name
  }

  data = {
    root-user     = "admin"
    root-password = random_password.minio_root[0].result
  }
}

# SSH private key secret for git-sync sidecar in the main site pod
resource "kubernetes_secret" "website_git_sync_ssh" {
  count = var.enable_website ? 1 : 0

  metadata {
    name      = "git-sync-ssh"
    namespace = kubernetes_namespace.simon_frey_com[0].metadata[0].name
  }

  data = {
    ssh = tls_private_key.website_deploy_key[0].private_key_openssh
  }
}

# ============================================================================
# I) Plausible Analytics — namespace + secrets
# ============================================================================

resource "kubernetes_namespace" "plausible" {
  metadata {
    name = "plausible"
  }

  depends_on = [helm_release.cilium]
}

resource "random_password" "plausible_clickhouse" {
  length  = 24
  special = false
}

resource "random_password" "plausible_secret_key" {
  length  = 64
  special = false
}

resource "random_password" "plausible_totp_vault" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "plausible_credentials" {
  metadata {
    name      = "plausible-credentials"
    namespace = kubernetes_namespace.plausible.metadata[0].name
  }

  data = {
    SECRET_KEY_BASE      = base64encode(random_password.plausible_secret_key.result)
    TOTP_VAULT_KEY       = base64encode(random_password.plausible_totp_vault.result)
    CLICKHOUSE_PASSWORD  = random_password.plausible_clickhouse.result
  }
}

