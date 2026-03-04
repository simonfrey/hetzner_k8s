# Decisions

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
