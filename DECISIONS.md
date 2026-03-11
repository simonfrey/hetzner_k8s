# Decisions

## 2026-03-11: Add CLICKHOUSE_PASSWORD to plausible-credentials secret

**Problem:** Plausible's `init-database` init container expects a `CLICKHOUSE_PASSWORD` key in the `plausible-credentials` secret. The key was previously removed, but the pascaliske/plausible Helm chart (v2.0.0) still references it.

**Fix:** Added `CLICKHOUSE_PASSWORD = ""` (empty string) to the secret in `argocd.tf`. This matches the ClickHouse config which uses an empty password.

## 2026-03-09: Replace Helm-based ClickHouse operator with kubectl manifest

**Problem:** The Altinity ClickHouse Helm chart (v0.26.0) deployed the operator pod with correct RBAC, but it never reconciled the ClickHouseInstallation CR. Root cause unclear — likely a bug in the Helm chart's controller setup.

**Fix:** Replaced with the upstream `clickhouse-operator-install-bundle.yaml` manifest from the Altinity GitHub repo, stored in `gitops/apps/clickhouse-operator/`. The ArgoCD app now uses a directory source instead of Helm. The manifest installs into `kube-system` namespace (upstream default).

## 2026-03-09: Deploy Plausible Analytics CE with database operators

**Goal:** Self-hosted privacy-focused analytics at `p.tools.simon-frey.com`.

**Stack:** Plausible CE (pascaliske Helm chart) + Zalando Postgres Operator + Altinity ClickHouse Operator.

**Why operators over StatefulSets:** Operators handle lifecycle management (backups, failover, upgrades) for databases. Even for single-instance setups, they provide proper schema management and credential rotation.

**Connection string pattern:** Kubernetes `$(VAR)` env var substitution to build `DATABASE_URL` from the operator-generated postgres password secret, avoiding Terraform dependency on operator-generated credentials.

## 2026-03-06: Remove CPU limit on vmagent to fix CPUThrottlingHigh alert

**Problem:** CPUThrottlingHigh alert firing for vmagent (38.75% throttling). The vm-operator applies a default CPU limit of 200m even when not explicitly set in values.yaml.

**Fix:** Explicitly set vmagent resource limits with only a memory limit (no CPU limit) in `gitops/apps/monitoring/values.yaml`. This follows the same pattern as commit `a490144` which removed CPU limits on other throttled resources.

**KubeAPIErrorBudgetBurn:** Also observed this alert — caused by transient post-deploy issues (etcd connection errors, vm-operator webhook TLS cert regeneration, metrics-server API unavailability). These are expected to self-resolve after cluster stabilization.

## 2026-02-12: Fix Windows Server 2022 KubeVirt VM configuration

**Problem:** Windows Server 2022 VM boots in KubeVirt but hangs at "click to continue" on VNC — the Windows installer never starts.

**Root causes identified:**
1. **ISO mounted as `disk` instead of `cdrom`** — Windows Setup doesn't recognize the installation media when mounted as a regular disk. Changed to `cdrom` device type.
2. **Missing SMM feature for UEFI** — The VM uses EFI boot but didn't enable System Management Mode (SMM), required by the official Windows 2022 KubeVirt template. Added `smm: {}`.
3. **Incomplete Hyper-V enlightenments** — Only had `relaxed`, `vapic`, `spinlocks`. Added: `frequencies`, `ipi`, `reenlightenment`, `reset`, `runtime`, `synic`, `tlbflush`, `vpindex` (per official template).
4. **Missing clock/timer configuration** — No timer config existed. Added HPET (disabled), Hyper-V timer, PIT (delay), RTC (catchup) with UTC clock. Especially important under software emulation where timing is degraded.

**Additional cleanup:**
- Removed `kvm`/`kvm_amd` kernel module loading and udev rules from kubevirt_worker Talos config — Hetzner Cloud does not support nested virtualization even on CCX dedicated vCPU instances. These modules had no effect.
- `useEmulation: true` in `kubevirt-cr.yaml` remains correct and required for Hetzner Cloud.

**Expected behavior after fix:** Windows Setup should start automatically via Autounattend.xml. Installation takes ~1-2 hours under software emulation (normal for Hetzner Cloud without KVM).

## 2026-02-13: Switch Windows VM to BIOS boot and fix ISO loading

**Problem:** Windows ISO never boots — VNC shows "no installation medium found" then "no bootable device found".

**Root causes identified:**
1. **CDI upload mangles ISOs** — `virtctl image-upload` with CDI DataVolumes treats ISOs as disk images and converts/resizes them (4.8G ISO became 7G raw file), corrupting the ISO 9660 structure. Replaced CDI DataVolume with a plain PVC and `kubectl cp` to copy the ISO byte-for-byte.
2. **OVMF (UEFI) cannot boot SATA CDROM under TCG software emulation** — Even with a valid EFI-bootable ISO (`/efi/boot/bootx64.efi` present, checksums verified), OVMF fails to find bootable media on the SATA CDROM when running under QEMU TCG (`-accel tcg`). Likely an AHCI timeout issue under software emulation. Switched to BIOS boot (SeaBIOS) which uses El Torito boot and works correctly.

**Changes made:**
- `windows-vm.yaml`: Replaced CDI DataVolume with plain PVC, added `firmware.bootloader.bios`, removed `firmware.bootloader.efi` and `smm` feature, swapped boot order (ISO=1, OS disk=2), changed volume reference from `dataVolume` to `persistentVolumeClaim`.
- `windows-sysprep.yaml`: Changed partition scheme from GPT/EFI (EFI+MSR+Primary) to MBR/BIOS (System Reserved+Primary) since BIOS boot requires MBR partitioning. Install target changed from partition 3 to partition 2.
- `post-deploy.sh`: Replaced `virtctl image-upload` (CDI upload proxy + port-forward) with `kubectl cp` via temporary iso-loader pod. Script now stops VM, copies ISO directly into PVC as `disk.img`, verifies byte count, then restarts VM.

## 2026-02-13: Switch ISO CDROM from SATA to virtio-scsi + wipe OS disk

**Problem:** Two issues blocking Windows installation:
1. **Error 0xc00000e9 (I/O error)** — Windows Boot Manager fails with "An unexpected I/O error has occurred" while loading `boot.wim` from the SATA CDROM. The AHCI/SATA controller emulation under QEMU TCG is unreliable for large sequential reads.
2. **GPT partition table leftover** — The OS disk PVC retained a GPT partition table from previous EFI boot attempts, causing "Der ausgewählte Datenträger entspricht dem GPT-Partitionsstil" when Windows Setup tries MBR partitioning in BIOS mode.

**Changes made:**
- `windows-vm.yaml`: Changed ISO CDROM bus from `sata` to `scsi` (virtio-scsi). Virtio-scsi is paravirtualized — bypasses the AHCI controller entirely, avoiding TCG timeout issues. SeaBIOS has a built-in virtio-scsi driver. Kept virtio-drivers and sysprep CDROMs on SATA (small reads, no timeout issue).
- `windows-sysprep.yaml`: Added `vioscsi\2k22\amd64` driver paths for D:\, E:\, F:\ in PnpCustomizationsWinPE. After SeaBIOS boots WinPE from the virtio-scsi CDROM, WinPE needs the vioscsi Windows driver to access the ISO for `install.wim`. The virtio-container-disk already includes these drivers.
- `post-deploy.sh`: Added `windows-os-disk` PVC as second volume mount in iso-loader pod. After ISO copy, wipes first 1MB of OS disk with `dd if=/dev/zero` to clear any leftover GPT/MBR partition table. Updated mount paths (`/mnt/iso`, `/mnt/os-disk`) and added wait for os-disk PVC to be Bound.

## 2026-02-18: Migrate from shell-script deployment to ArgoCD GitOps

**Problem:** The cluster was deployed via `terraform apply` (infrastructure) followed by `scripts/post-deploy.sh` — a 686-line shell script that sequentially installs 10+ components via helm/kubectl. This approach is fragile (no retries on transient failures), has no drift detection, no self-healing, requires manual re-runs, and makes it hard to track what's deployed vs. what should be.

**Decision:** Migrate to ArgoCD-based GitOps using the app-of-apps pattern with sync waves for ordering.

**Architecture:**
- **Terraform** bootstraps the minimum required before ArgoCD can function: Cilium CNI (nodes are NotReady without it) and ArgoCD itself, plus secrets/ConfigMaps that contain Terraform-generated values (passwords, tokens, cloud-init configs)
- **ArgoCD** manages everything else from the `gitops/` directory in git: CCM, CSI, metrics-server, Traefik, cert-manager, cert-issuers, KubeVirt, CDI, Windows VM, cluster autoscaler, and optionally monitoring
- Sync waves (-5 through 5) enforce installation order
- `ServerSideApply=true` used for operator apps (KubeVirt, CDI) whose CRDs exceed the annotation size limit
- Multi-source used for monitoring (upstream Helm chart + local values file)

**Secret handling:** Passwords are generated by `random_password` in Terraform and stored in Terraform state. Terraform creates `kubernetes_secret` and `kubernetes_config_map` resources that ArgoCD-managed apps reference. This keeps secrets out of git while allowing ArgoCD to manage the workloads.

**Changes made:**
- `main.tf`: Added `helm`, `kubernetes`, `random` providers configured via Talos kubeconfig
- `variables.tf`: Added `git_repo_url`, `git_target_revision`, `enable_monitoring`, `enable_windows_vm`
- `argocd.tf` (new): Cilium + ArgoCD helm_release, random_password resources, namespace/secret/configmap resources, root Application
- `templates/` (new): `autounattend.xml.tftpl`, `user-mapping.xml.tftpl` — extracted from manifests with Terraform variable interpolation
- `outputs.tf`: Added password outputs, ArgoCD admin password command, updated summary
- `gitops/root-app/`: App-of-apps Helm chart with 13 ArgoCD Application templates
- `gitops/apps/`: Individual app directories (cert-issuers, kubevirt-operator, kubevirt-cr, cdi-operator, cdi-cr, windows, autoscaler, monitoring)
- `scripts/post-deploy.sh`: Simplified to ~50 lines (kubeconfig fetch + status display)
- `scripts/copy-windows-iso.sh` (new): Extracted ISO copy logic for manual use
- Old manifests in `manifests/` deleted (migrated to `gitops/apps/`)

## 2026-02-18: Fix ArgoCD Helm release pre-install timeout

**Problem:** `helm_release.argocd` times out after 10 minutes with `failed pre-install: timed out waiting for the condition`. The argo-cd Helm chart (v7.8.13) has a `redis-secret-init` pre-install hook Job. The Job pod fails with `FailedScheduling: 0/3 nodes are available: 3 node(s) had untolerated taint(s)`.

**Root cause (1 — scheduling):** All nodes have the `node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule` taint, added by Kubernetes when a cloud provider is configured. This taint is removed by the Hetzner Cloud Controller Manager (CCM), but CCM is deployed by ArgoCD — creating a chicken-and-egg problem. ArgoCD only tolerated `node-role.kubernetes.io/control-plane`, not the cloud-provider taint.

**Root cause (2 — DNS readiness):** After Cilium reports Ready, CoreDNS may still be starting. Without DNS, image pulls from external registries (`quay.io`) would fail.

**Fix:**
1. Added `node.cloudprovider.kubernetes.io/uninitialized` toleration to ArgoCD's `global.tolerations` (via `values = [yamlencode(...)]` for clean YAML array syntax with two tolerations)
2. Added `null_resource.wait_for_coredns` between Cilium and ArgoCD that polls CoreDNS deployment readiness (up to 5 minutes) before allowing ArgoCD install to proceed

## 2026-02-18: Fix KubeVirt operator ArgoCD ComparisonError

**Problem:** The kubevirt-operator ArgoCD Application fails with `ComparisonError: Failed to compare desired state to live state: failed to calculate diff: error calculating structured merge diff: error building typed value from live resource: .status.terminatingReplicas: field not declared in schema`.

**Root cause:** The Application uses `ServerSideApply=true` (needed because the KubeVirt CRD exceeds the `last-applied-configuration` annotation size limit). ArgoCD's client-side structured merge diff tries to build typed values from live resources using the CRD's OpenAPI schema. The KubeVirt operator writes `.status.terminatingReplicas` at runtime, but this field isn't declared in the CRD schema shipped in v1.7.0. The diff fails before it can even compare.

**Fix:** Added `ServerSideDiff=true` to the kubevirt-operator Application's syncOptions. This delegates diff calculation to the Kubernetes API server, which handles unknown/unstructured status fields correctly. This is the recommended complement to `ServerSideApply=true` per ArgoCD docs.

## 2026-02-18: Automate Windows ISO copy in Terraform apply

**Problem:** After the GitOps migration, the Windows VM has `runStrategy: Always` so ArgoCD starts it immediately at sync wave 3 — but the ISO PVC is empty. The ISO copy (`scripts/copy-windows-iso.sh`) was a manual step that's easy to miss. Since the project policy is "terraform destroy and setup from 0", the ISO PVC is always empty after a fresh deploy.

**Fix:**
1. Added `null_resource.copy_windows_iso` in `argocd.tf` that runs `scripts/copy-windows-iso.sh` after the ArgoCD root application is deployed, gated by `var.enable_windows_vm`. The provisioner writes `.kubeconfig` from `talos_cluster_kubeconfig` (with server address rewritten for the WireGuard tunnel) before invoking the script.
2. Changed `runStrategy` from `Always` to `Stopped` in `gitops/apps/windows/templates/vm.yaml` so the VM doesn't boot with an empty ISO PVC. The `copy-windows-iso.sh` script already patches it back to `Always` after the ISO is copied (line 122).

This makes `terraform apply` fully self-contained — no manual post-deploy step needed for the Windows ISO.

## 2026-02-19: Remove background progress monitor from ISO copy script

**Problem:** `copy-windows-iso.sh` gets stuck at ~7% during ISO upload. The background subshell runs `kubectl exec` every 30s to check file size on the pod, which interferes with the concurrent `kubectl cp` SPDY connection to the same pod/container.

**Attempted fix:** Replaced `kubectl cp` with `pv | kubectl exec -i -- cat > file` foreground pipe. Failed — raw stdin piping of ~5GB through `kubectl exec` causes immediate SPDY/WebSocket connection reset ("broken pipe" / "connection reset by peer"). The API server connection isn't designed for large raw binary transfers via exec stdin.

**Fix:** Removed the background progress monitor entirely and kept plain `kubectl cp` (which uses tar internally and handles large file streaming correctly). The transfer itself was never the problem — only the competing `kubectl exec` calls from the background monitor caused the stall.

## 2026-02-20: Flip boot order so Windows boots from disk after installation

**Problem:** After Windows Server 2022 installs successfully and reboots, the VM gets stuck at "Press any key to boot from CD/DVD... No operating system found." SeaBIOS tries the ISO CDROM first (bootOrder: 1) and fails to fall through to the virtio OS disk (bootOrder: 2).

**Fix:** Swapped boot order in `gitops/apps/windows/templates/vm.yaml`: OS disk is now bootOrder: 1, ISO is bootOrder: 2. After installation, the VM boots directly from the hard drive. The ISO remains available as a fallback but is no longer tried first.

## 2026-02-24: Disable KubeVirt worker node and Windows VM (cost savings)

**Change:** Set `enable_windows_vm` default to `false` and added `count = var.enable_windows_vm ? 1 : 0` to the `hcloud_server.kubevirt_worker` resource. The dedicated CCX instance for KubeVirt is expensive and not currently needed. All Windows VM related resources (namespace, secrets, configmaps, ISO copy) were already gated behind `enable_windows_vm`. To re-enable, set `enable_windows_vm = true` in `terraform.tfvars`.

## 2026-03-03: Host simon-frey.com on Kubernetes

**Decision:** Deploy simon-frey.com as three services in the `simon-frey-com` namespace, managed via ArgoCD:

1. **Main site** — Apache+PHP with git-sync sidecar cloning the private `simonfrey/simon-frey.com` repo. Auto-updates within 60s of git push.
2. **WordPress blog** at `/blog` — WordPress 6 + MySQL 8.0 with persistent storage. DB restore is a one-time manual step.
3. **MinIO file storage** at `/files` — S3-compatible storage with anonymous read on a `public` bucket. Admin console on `files-admin.simon-frey.com`.

**Key design choices:**
- **git-sync sidecar** instead of CI/CD image builds — simpler, no registry needed, instant updates for a PHP site
- **SSH deploy key** generated by Terraform — ArgoCD and git-sync both use it to access the private repo
- **Traefik path-based routing** — single Ingress for main+blog, separate Ingress for `/files` with `replacePathRegex` middleware to rewrite `/files/` → `/public/` (MinIO bucket name)
- **Feature flag** `enable_website` — gates all resources (namespace, secrets, ArgoCD apps) behind a variable, consistent with existing `enable_windows_vm` and `enable_monitoring` patterns
- **Passwords** — MySQL root/user and MinIO root passwords generated by Terraform `random_password`, stored in K8s secrets, never in git

**DNS requirement:** User must point `simon-frey.com` and `files-admin.simon-frey.com` A records to the Hetzner load balancer IP.

## 2026-02-18: Fix invalid KubeVirt RunStrategy "Stopped"

**Problem:** Windows VM shows "Boot failed: Could not read from CDROM (code 0005)". The ISO PVC was empty because the copy script never actually stopped the VM before copying.

**Root cause:** `Stopped` is not a valid KubeVirt RunStrategy — valid values are `Always`, `Halted`, `Manual`, `RerunOnFailure`. The copy script (line 39) used `runStrategy: Stopped` to halt the VM before copying the ISO. The KubeVirt webhook rejected the patch, but `|| true` silenced the error. The VM kept running with QEMU holding the empty PVC file open, so the copied ISO data was never seen by QEMU. Additionally, ArgoCD couldn't sync the VM manifest with `runStrategy: Stopped` (same webhook rejection).

**Fix:**
1. `gitops/apps/windows/templates/vm.yaml`: Changed `runStrategy` from `Stopped` to `Always` — the desired end state. ArgoCD syncs cleanly; the copy script patches it to `Halted` temporarily then back to `Always`.
2. `scripts/copy-windows-iso.sh`: Changed the stop patch from `Stopped` to `Halted` (valid KubeVirt value). The flow is now: halt VM → copy ISO → patch back to `Always` → VM restarts with ISO.

## 2026-03-05: Fix cluster autoscaler RBAC and worker management

**Problem:** Cluster autoscaler (v1.35.0) is completely broken — stuck in infinite RBAC error retry loops, never entering the main scaling loop. Zero scaling decisions are made.

**Root causes:**
1. **Missing RBAC permissions** — ClusterRole lacked `resource.k8s.io` (resourceclaims, resourceslices, deviceclasses, resourceclaimtemplates) and `storage.k8s.io/volumeattachments`, required by autoscaler v1.35.0. The informer watches fail immediately, preventing initialization.
2. **Terraform-managed static workers conflict with autoscaler** — `initial_worker_count = 2` creates 2 permanent workers via Terraform that the autoscaler can't scale down (would cause state drift).
3. **Location case mismatch** — `--nodes` flags used `NBG1`/`HEL1` (uppercase) but Hetzner API uses lowercase `nbg1`/`hel1`.

**Changes:**
- `gitops/apps/autoscaler/cluster-autoscaler.yaml`: Added RBAC rules for `resource.k8s.io` and `storage.k8s.io/volumeattachments`. Fixed location names to lowercase.
- `terraform.tfvars`: Changed `initial_worker_count` from 2 to 0 so the autoscaler fully manages worker lifecycle.
- `gitops/apps/autoscaler/cluster-autoscaler.yaml`: Reduced memory requests from 300Mi to 128Mi (limit 256Mi) so pod fits on cp-1 (cx23, 4GB RAM at 97% utilization).
- `gitops/apps/kubevirt-cr/kubevirt-cr.yaml`: Added `infra.nodePlacement` with `kubevirt=true` nodeSelector so KubeVirt infrastructure pods (virt-operator, virt-api, virt-controller ~685Mi) only run on dedicated kubevirt nodes, freeing memory on cp-1.

## 2026-03-05: Add kwatch for cluster monitoring with Pushover notifications

**Decision:** Deploy kwatch (v0.10.3) to monitor all namespaces, PVCs, and nodes. Notifications go to Pushover via their native webhook feature (no adapter needed).

**Architecture:**
- kwatch sends JSON payloads to a Pushover webhook URL
- Pushover extracts notification title/body using JSON selectors configured in the Pushover dashboard
- The webhook URL (contains secret token) is stored in a Terraform-managed ConfigMap, never committed to git

**Files created:**
- `gitops/apps/kwatch/` — namespace, RBAC, deployment manifests (no secrets)
- `gitops/root-app/templates/kwatch.yaml` — ArgoCD Application (sync-wave 5)
- `argocd.tf` — namespace + ConfigMap with webhook URL from `var.pushover_webhook_url`
- `variables.tf` — `pushover_webhook_url` variable (sensitive)

## 2026-03-05: Taint control-plane node to restrict scheduling

**Problem:** cp-1 (cx22, 4GB RAM) has no taint, so all pods — including application workloads (WordPress, MySQL, MinIO, simon-frey.com) — schedule there, causing memory pressure.

**Decision:** Taint cp-1 with `node-role.kubernetes.io/control-plane:NoSchedule` so only infrastructure services with explicit tolerations run there. Application pods become Pending until the cluster autoscaler provisions worker nodes.

**Changes:**
- `talos.tf`: Set `allowSchedulingOnControlPlanes = false` (Talos applies the standard control-plane taint)
- `gitops/root-app/templates/ccm.yaml`: Added control-plane + cloud-provider-uninitialized tolerations
- `gitops/root-app/templates/csi.yaml`: Added control-plane tolerations for controller and node components
- `gitops/root-app/templates/cert-manager.yaml`: Added control-plane tolerations for main, cainjector, and webhook
- `gitops/root-app/templates/metrics-server.yaml`: Added control-plane toleration

**Already configured (no changes needed):** ArgoCD (global.tolerations in argocd.tf), Traefik (traefik.yaml), cluster autoscaler (cluster-autoscaler.yaml), Cilium (DaemonSet tolerates all), CoreDNS (system component), KubeVirt/CDI (restricted to kubevirt=true nodes).

**Deployment order:** Sync ArgoCD apps first (tolerations), then apply taint (or let Terraform update Talos config).

## 2026-03-05: Add Prometheus Alertmanager with Pushover notifications

**Problem:** Alertmanager is deployed via kube-prometheus-stack but has no receivers configured — all ~100 default PrometheusRules (KubeNodeNotReady, KubePodCrashLooping, etc.) fire but go nowhere.

**Decision:** Configure Alertmanager's native pushover receiver to send notifications via Pushover. Credentials stored in a Terraform-managed Kubernetes secret, mounted into Alertmanager via `alertmanagerSpec.secrets`.

**Changes:**
- `variables.tf`: Added `pushover_user_key` and `pushover_api_token` variables (sensitive)
- `argocd.tf`: Added `kubernetes_secret.alertmanager_pushover` (gated by `enable_monitoring`)
- `gitops/apps/monitoring/values.yaml`: Added Alertmanager config with pushover receiver, null receiver for Watchdog/InfoInhibitor, and secret mount
- Credentials use `user_key_file`/`token_file` (file-based) so secrets never appear in the Alertmanager config YAML

## 2026-03-05: Gate KubeVirt and CDI behind enableWindows flag

**Problem:** KubeVirt and CDI pods are stuck Running on cp-1 despite nodePlacement changes (commit `6c1cba3`). The operators created new ReplicaSets with `kubevirt: "true"` nodeSelector, but new pods can't schedule (no kubevirt nodes exist when `enable_windows_vm=false`), so old pods on cp-1 are never terminated (rolling update deadlock).

**Root cause:** The 4 ArgoCD apps (kubevirt-operator, kubevirt-cr, cdi-operator, cdi-cr) are always deployed regardless of `enableWindows`. Only the windows VM app was gated. Additionally, virt-operator had `kubevirt: "true"` nodeSelector, preventing it from running on the control plane where it needs to be to manage KubeVirt CRs.

**Changes:**
- `gitops/root-app/templates/{kubevirt-operator,kubevirt-cr,cdi-operator,cdi-cr}.yaml`: Wrapped in `{{- if .Values.enableWindows }}` / `{{- end }}`, matching the existing pattern in `windows.yaml`. When `enableWindows=false`, ArgoCD prunes these Applications and their child resources.
- `gitops/apps/kubevirt-operator/kubevirt-operator.yaml`: Reverted virt-operator Deployment nodeSelector to just `kubernetes.io/os: linux` (removed `kubevirt: "true"`). Added control-plane and master tolerations so the operator can schedule on cp-1. Kept kubevirt toleration for when dedicated nodes exist.

## 2026-03-06: Fix worker NotReady — upgrade CP to cx33, add PDBs, move monitoring off CP

**Problem:** Worker node goes NotReady every ~30 min. Root cause: control plane (cx23, 2vCPU/4GB) is overloaded — kube-apiserver has 56 restarts, controller-manager 82, scheduler 81 in 15 days. When API server crashes, kubelet can't heartbeat → NotReady → website down.

**Changes (staged for zero website downtime):**

1. **PodDisruptionBudgets** for all website components (simon-frey-com-main, nginx-cache, wordpress, mysql) with `minAvailable: 1` — prevents autoscaler/drain from killing all pods simultaneously
2. **Autoscaler min nodes 0→1** — ensures at least one worker always exists
3. **Monitoring moved off control plane** — removed control-plane tolerations from vmsingle, vmagent, vmalert, alertmanager, grafana, VM operator (kept for node-exporter DaemonSet). Frees ~1.5GB RAM on CP
4. **Autoscaler skip-system-pods=true** — prevents autoscaler from draining nodes with system pods
5. **Worker nodes upgraded cx23→cx33** — autoscaler node groups changed to cx33 (more headroom for workloads)
6. **Control plane upgraded cx23→cx33** (8GB RAM) — new `cp_server_type` variable separates CP sizing from worker sizing. Requires `terraform apply` (CP recreation, ~2-3 min API downtime, website stays up via autonomous kubelet)

## 2026-03-06: Enable ServerSideApply globally for all ArgoCD apps

**Problem:** The monitoring ArgoCD app sync failed permanently (exhausted 5 retries) because 6 large prometheus-operator CRDs exceed the 262144-byte `kubectl.kubernetes.io/last-applied-configuration` annotation limit. Without these CRDs, no Prometheus or Alertmanager pods are created.

**Decision:** Enable `ServerSideApply=true` globally for all ArgoCD apps, not just the ones with known large CRDs. SSA avoids the annotation size limit entirely and is the recommended approach per ArgoCD docs.

**Changes:**
- `gitops/root-app/templates/_helpers.tpl`: Added `syncOptions: [ServerSideApply=true]` to the shared syncPolicy helper (covers 10+ apps using the helper)
- `gitops/root-app/templates/cert-manager.yaml`: Added `ServerSideApply=true` to inline syncOptions
- `gitops/root-app/templates/traefik.yaml`: Added `ServerSideApply=true` to inline syncOptions
- Already had SSA: monitoring.yaml, kubevirt-operator.yaml, cdi-operator.yaml

## 2026-03-06: Migrate from Prometheus to VictoriaMetrics

**Problem:** kube-prometheus-stack works but VictoriaMetrics is more resource-efficient for small clusters — lower memory/CPU usage for the same functionality.

**Decision:** Replace `kube-prometheus-stack` with `victoria-metrics-k8s-stack` Helm chart. The VM operator auto-converts Prometheus CRDs (ServiceMonitor→VMServiceScrape, PrometheusRule→VMRule), so existing scrape targets from other apps carry over without changes.

**Changes:**
- `gitops/root-app/templates/monitoring.yaml`: Changed Helm repo to `victoriametrics.github.io/helm-charts`, chart to `victoria-metrics-k8s-stack` v0.72.4
- `gitops/apps/monitoring/values.yaml`: Rewritten for VM stack structure — vmsingle (replaces Prometheus), vmagent, vmalert, alertmanager (same Pushover config), grafana (datasource auto-pointed to VMSingle), vm-operator, node-exporter, kube-state-metrics
- No Terraform changes — `alertmanager-pushover` and `grafana-admin` secrets stay the same
- Alertmanager secret mount path changed from `/etc/alertmanager/secrets/` to `/etc/vm/secrets/` (VMAlertmanager convention)

**Trade-offs:**
- No historical metric data migration — VictoriaMetrics starts fresh (7-day retention means full coverage within a week)
- VM operator auto-converts any existing ServiceMonitor/PodMonitor CRDs, so nothing else in the cluster needs changing
- Old Prometheus resources are fully pruned by ArgoCD (prune: true)

## 2026-03-06: Replace kubectl cp ISO loading with CDI DataVolume HTTP import

**Problem:** Windows Server ISO was loaded via a 165-line bash script (`scripts/copy-windows-iso.sh`) that halts the VM, creates a temp pod, chunks the ISO into 50MB pieces, `kubectl cp`s them with retries, reassembles, and restarts the VM. This complex script was orchestrated by a Terraform `null_resource` provisioner, creating a dependency outside GitOps.

**Root cause analysis:** The original CDI rejection (2026-02-13) was due to `virtctl image-upload` corruption. That tool uses CDI's upload proxy which applies conversion/resize logic. HTTP import via DataVolume is a different code path — CDI downloads the file directly and treats ISOs as raw images (ISO 9660 is already raw, so no conversion occurs).

**Decision:** Replace kubectl cp workflow with a CDI DataVolume using `source.http.url` pointing directly to Microsoft's Windows Server 2022 evaluation ISO download URL.

**Changes:**
- `gitops/apps/windows/templates/datavolume-iso.yaml` (new): CDI DataVolume with HTTP source, 7Gi storage, storageClass `hcloud-volumes-nbg1`
- `gitops/apps/windows/templates/pvc-iso.yaml` (deleted): Replaced by DataVolume which auto-creates a PVC with the same name
- `argocd.tf`: Removed `null_resource.copy_windows_iso` block
- `scripts/copy-windows-iso.sh` (deleted): No longer needed
- `CLAUDE.md`: Updated ISO loading documentation
- VM spec unchanged — `persistentVolumeClaim.claimName: windows-iso` works with DataVolume-created PVC
- KubeVirt automatically waits for DataVolume import to complete before starting the VM

## 2026-03-07: Remove all CPU limits to fix CPUThrottlingHigh alerts

**Problem:** CPUThrottlingHigh alerts firing for git-sync (65% throttling) and vmagent (25% throttling). CPU limits cause CFS throttling without benefit on a small cluster. The vm-operator also injects default CPU limits via `USEDEFAULTRESOURCES=true` even when not specified in values.yaml.

**Decision:** Remove all CPU limits across the cluster. Keep memory limits (prevent OOM) and all requests (scheduling). Disable vm-operator default resource injection so it doesn't re-add CPU limits to vmagent, vmalert, vmsingle, and alertmanager.

**Changes:**
- `gitops/apps/simon-frey-com-main/deployment.yaml`: Removed `cpu: 100m` limit from git-sync container
- `gitops/apps/monitoring/values.yaml`: Removed CPU limits from vmsingle (500m), vmalert (200m), alertmanager (100m), vm-operator (200m), grafana (200m). Added `VM_VM*DEFAULT_USEDEFAULTRESOURCES=false` env vars to vm-operator to prevent default CPU limit injection on VM CRs.

## 2026-03-09: Fix Plausible — ClickHouse auth + Postgres SSL (Option A)

**Problem:** Plausible crashlooping (Init:Error) with 5 interrelated issues:
1. ClickHouse operator auto-generates `chop-generated-users.xml` restricting the `default` user to ClickHouse pod IPs only — Plausible connects from a different pod IP → rejected.
2. ClickHouse v26.2.4 requires a password for the `default` user (`REQUIRED_PASSWORD`) — Plausible had no credentials in `CLICKHOUSE_DATABASE_URL`.
3. Previous attempt to override `default/networks/ip` in CHI spec didn't take effect — operator-generated config takes precedence.
4. Zalando Postgres operator's Patroni prepends `hostnossl all all all reject` before user-specified pg_hba rules — non-SSL connections rejected.
5. `DATABASE_URL` used `sslmode=disable`, forcing non-SSL connections that hit issue 4.

**Decision:** Option A — adapt Plausible's connection config to work with operator defaults instead of fighting them.

**Changes:**
- `gitops/apps/plausible/clickhouse.yaml`: Replaced ineffective `default/networks/ip` with a dedicated `plausible` user with password (from `plausible-credentials` secret via `valueFrom.secretKeyRef`), open network (`::/0`), and default profile/quota.
- `gitops/root-app/templates/plausible.yaml`: Changed `DATABASE_URL` from `sslmode=disable` to `sslmode=require` (Zalando operator provides SSL certs). Added `CH_PASSWORD` env from secret, updated `CLICKHOUSE_DATABASE_URL` to include `plausible:<password>` credentials.
- `argocd.tf`: Added `random_password.plausible_clickhouse` (24 chars, no special) and added `CLICKHOUSE_PASSWORD` to the existing `plausible-credentials` secret.

## 2026-03-09: Fix Plausible — ClickHouse user creation + Postgres SSL removal

**Problem:** Two remaining issues after Option A implementation:
1. ClickHouse `plausible` user was never created — `valueFrom.secretKeyRef` YAML syntax was silently ignored by the operator. The `chop-generated-users.xml` configmap only contained `default` and `clickhouse_operator`.
2. Postgres connections failed with `no encryption` — `sslmode=require` in DATABASE_URL wasn't taking effect (possibly Postgrex URL parsing or URL-breaking characters in the Zalando-generated password).

**Changes:**
- `gitops/apps/plausible/clickhouse.yaml`: Switched from `valueFrom.secretKeyRef` to the string-based `k8s_secret_password` format (`namespace/secret/key`), which is the documented and proven approach for the ClickHouse operator. Bumped reconcile-trigger to "3".
- `gitops/root-app/templates/plausible.yaml`: Removed `?sslmode=require` from DATABASE_URL. The pg_hba config already allows non-SSL via `host all all 0.0.0.0/0 md5`.

## 2026-03-10: Fix Plausible — ClickHouse files override + Terraform-managed Postgres password

**Problem (Round 3):** Plausible crashlooping 22h (259+ restarts). Two issues:
1. ClickHouse operator ignores `default/networks/ip` in CHI spec — `chop-generated-users.xml` always restricts `default` to localhost + pod IPs. Also requires password (`REQUIRED_PASSWORD`).
2. Postgres `no encryption` — Zalano-generated password contains URL-breaking chars, corrupting `DATABASE_URL` so `?sslmode=require` is never parsed.

**Fix 1 — ClickHouse (`configuration.files` override):** The operator controls the `default` user in `chop-generated-users.xml` and ignores CHI spec overrides for it. Used `spec.configuration.files` to inject `users.d/plausible-override.xml` — a custom XML file that sets `default` user with empty password and `::/0` network access. ClickHouse merges XML configs alphabetically, so `plausible-override.xml` loads after `chop-generated-users.xml` and wins.

**Fix 2 — Postgres (Terraform-managed password):** Imported the existing Zalano credentials secret into Terraform state, then `terraform apply` overwrote the password with `random_password.plausible_postgres` (24 chars, `special=false`). Restarted Postgres pod to reload credentials. Safe password means `?sslmode=require` works in `DATABASE_URL`.

**Changes:**
- `gitops/apps/plausible/clickhouse.yaml`: Added `configuration.files` with `users.d/plausible-override.xml`, bumped reconcile-trigger to "5"
- `gitops/root-app/templates/plausible.yaml`: Removed CH_PASSWORD env, simplified CLICKHOUSE_DATABASE_URL to `http://default@...`, added `?sslmode=require` to DATABASE_URL
- `argocd.tf`: Replaced `random_password.plausible_clickhouse` with `random_password.plausible_postgres`, removed CLICKHOUSE_PASSWORD from secret, added `kubernetes_secret.plausible_postgres_credentials` (imported existing secret into TF state)

## 2026-03-06: Move cert-manager and metrics-server off control plane

**Problem:** CP node (cx33) is overloaded — kube-apiserver, scheduler, and controller-manager crash repeatedly. Every non-essential pod on CP adds to memory/CPU pressure.

**Decision:** Remove control-plane tolerations from cert-manager and metrics-server. Both can run on worker nodes — cert-manager is sync-wave -1 (workers exist by then, CCM is -5) and metrics-server is sync-wave -3 (only needs a kubelet endpoint). Kept CSI controller toleration despite it being a Deployment, because CSI is sync-wave -4 and during bootstrap the only node may be CP.

**Changes:**
- `gitops/root-app/templates/cert-manager.yaml`: Removed tolerations from main, cainjector, and webhook
- `gitops/root-app/templates/metrics-server.yaml`: Removed tolerations block

## 2026-03-11: Fix Plausible ClickHouse + Postgres auth (Round 4)

**Problem:** Two auth failures:
1. ClickHouse: `plausible` user created with `password: ""` in CHI spec, but the operator hashes this into a non-empty `password_sha256_hex` — passwordless connections rejected.
2. Postgres: `DATABASE_URL` missing `?sslmode=require` — Zalando operator's default pg_hba rejects non-SSL with `hostnossl all all all reject`.

Also: `random_password.plausible_postgres` and `kubernetes_secret.plausible_postgres_credentials` documented in earlier decisions were never added to `argocd.tf`. The Zalando operator auto-generates credentials, and this time the password has no URL-breaking chars, so we rely on the operator-generated secret directly.

**Fix:**
1. ClickHouse: Added `random_password.plausible_clickhouse` in Terraform, stored in `plausible-credentials` secret as `CLICKHOUSE_PASSWORD`. CHI spec uses `k8s_secret_password: plausible/plausible-credentials/CLICKHOUSE_PASSWORD` (operator's documented format for reading passwords from K8s secrets). Connection URL includes `plausible:$(CH_PASSWORD)@`.
2. Postgres: Added `?sslmode=require` to `DATABASE_URL`.

**Changes:**
- `argocd.tf`: Added `random_password.plausible_clickhouse`, changed `CLICKHOUSE_PASSWORD` from `""` to the generated password.
- `gitops/apps/plausible/clickhouse.yaml`: Changed `plausible/password: ""` to `plausible/k8s_secret_password: plausible/plausible-credentials/CLICKHOUSE_PASSWORD`. Bumped reconcile-trigger to "7".
- `gitops/root-app/templates/plausible.yaml`: Added `CH_PASSWORD` env from secret, included password in `CLICKHOUSE_DATABASE_URL`, added `?sslmode=require` to `DATABASE_URL`.
