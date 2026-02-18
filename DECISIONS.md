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
