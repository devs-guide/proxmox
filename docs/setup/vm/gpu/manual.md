# Proxmox whole-GPU passthrough test runbook

This runbook prepares one Proxmox VE 6.4 or 9.x node for whole-GPU
passthrough, verifies the host after reboot, and attaches the complete PCI slot
to one stopped QEMU VM. Run every command on the Proxmox node as `root`.

The initial runner is intentionally narrow. It supports direct node-local PCI
addresses, Q35 VMs, exact-BDF VFIO reservation, optional dedicated-host driver
blacklisting, attachment, testing, and rollback. It does not configure ACS
override, downloaded ROMs, SR-IOV/vGPU, guest drivers, or GPU-reset patches.

## Safety boundaries

- PCI passthrough dedicates the selected device to one VM and prevents normal
  live migration while it is attached.
- `--blacklist-host-drivers` disables AMD and NVIDIA display drivers for
  **every GPU on the host**. Use it only on a dedicated passthrough node with
  working out-of-band access.
- The runner does not bind by vendor/device ID. Five identical WX 4100 cards
  share the same IDs, so ID-based binding would capture all five. The generated
  initramfs script reserves only the selected PCI functions.
- A desktop profile disables the VM's virtual VGA. Configure SSH, RDP, VNC, or
  another guest recovery channel before attaching the physical GPU.
- The target VM must be stopped and non-HA. Desktop profiles additionally
  require Q35, OVMF, and an EFI disk. Converting an installed SeaBIOS/i440fx VM
  is outside this procedure.

## Example values

| Value | Meaning |
| --- | --- |
| `101` | Target QEMU VM ID |
| `0000:18:00.0` | Selected WX 4100 VGA function |
| `0000:18:00.1` | HDMI/DisplayPort audio function discovered automatically |
| `macos` | Primary-display guest profile; `winos` and `linux` behave similarly |
| `compute` | Secondary accelerator profile that retains virtual VGA |

Confirm the selected physical card before continuing. The shortened `18:00`
value later passed to `qm` includes both `.0` and `.1` functions.

```bash
lspci -Dnnk -s 0000:18:00.0
lspci -Dnnk -s 0000:18:00.1
qm status 101
qm config 101
```

## Download the feature-branch runner

Before merge, download the exact feature branch for remote testing:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/devs-guide/proxmox/feature/vm/gpu/setup/vm/gpu.sh \
  -o /tmp/proxmox-vm-gpu.sh
chmod 0755 /tmp/proxmox-vm-gpu.sh
/tmp/proxmox-vm-gpu.sh --help
```

After a successful merge and Pages deployment, the stable URL will be:

```text
https://devs-guide.github.io/proxmox/setup/vm/gpu.sh
```

## 1. Run read-only preflight

Preflight proves that the full slot is discoverable, all functions share an
isolated IOMMU group, no other VM owns the address, and VM 101 is stopped and
compatible with the selected profile.

```bash
/tmp/proxmox-vm-gpu.sh \
  --action preflight \
  --vm 101 \
  --gpu 0000:18:00.0 \
  --profile macos
```

If IOMMU is not active yet, preflight reports that host preparation and reboot
are required. `prepare --dry-run` remains available so a new host can review
the planned changes before IOMMU groups exist.

## 2. Review and prepare the host

Review the dedicated-host change first:

```bash
/tmp/proxmox-vm-gpu.sh \
  --action prepare \
  --gpu 0000:18:00.0 \
  --blacklist-host-drivers \
  --allow-host-display-loss \
  --yes \
  --dry-run
```

Apply it and explicitly reboot the host:

```bash
/tmp/proxmox-vm-gpu.sh \
  --action prepare \
  --gpu 0000:18:00.0 \
  --blacklist-host-drivers \
  --allow-host-display-loss \
  --yes \
  --reboot
```

`--reset` is accepted as an alias for `--reboot`. Without either flag, prepare
writes and rebuilds the boot artifacts but leaves the reboot to the operator.

Preparation performs these bounded changes:

- adds the CPU-appropriate `intel_iommu=on` or `amd_iommu=on` parameter plus
  `iommu=pt` through GRUB or `/etc/kernel/cmdline`;
- loads the three current VFIO modules and includes `vfio_virqfd` on PVE 6;
- installs an initramfs hook and early script for exactly `0000:18:00.0` and
  `0000:18:00.1`;
- optionally blacklists AMD/NVIDIA host display drivers globally;
- rebuilds GRUB or Proxmox boot entries and all initramfs images; and
- records non-secret ownership state under
  `/etc/ansible/proxmox/gpu-passthrough/`.

## 3. Run the post-reboot test gate

After the node returns, run `--test`. It exits nonzero unless the configured
kernel parameters, IOMMU isolation, VFIO modules, exact function bindings, and
VM preflight all pass.

```bash
/tmp/proxmox-vm-gpu.sh \
  --test \
  --vm 101 \
  --gpu 0000:18:00.0 \
  --profile macos
```

For machine-readable automation:

```bash
/tmp/proxmox-vm-gpu.sh \
  --test \
  --vm 101 \
  --gpu 0000:18:00.0 \
  --profile macos \
  --output json
```

Do not attach the GPU until the result contains `"ready":true`.

## 4. Attach the GPU

Desktop profiles add `pcie=1,x-vga=1` and set the virtual display to `none`.
The runner chooses the lowest unused `hostpciN` and does not replace existing
PCI assignments.

```bash
/tmp/proxmox-vm-gpu.sh \
  --action attach \
  --vm 101 \
  --gpu 0000:18:00.0 \
  --profile macos \
  --allow-guest-console-loss \
  --yes
```

Inspect the resulting configuration before starting:

```bash
qm config 101 | grep -E '^(bios|machine|efidisk0|vga|hostpci[0-9]+):'
/tmp/proxmox-vm-gpu.sh --action status --vm 101 --gpu 0000:18:00.0
qm start 101
```

For a Linux compute VM, retain noVNC/SPICE by using `--profile compute`; that
profile omits `x-vga=1` and does not change `vga`.

## 5. Confirm guest and reset behavior

Verify the hardware inside the guest:

- macOS: `system_profiler SPDisplaysDataType`
- Windows PowerShell: `Get-PnpDevice -Class Display`
- Linux: `lspci -nnk` and `dmesg | grep -i amdgpu`

Then perform one controlled stop/start cycle. This releases and reacquires the
VFIO device, exercising the GPU reset path more accurately than an in-guest
restart:

```bash
qm shutdown 101 --timeout 60
qm status 101
qm start 101
journalctl -b -k | grep -Ei 'vfio|reset|AMD_POLARIS|BAR|IOMMU'
```

If the second start fails or the GPU remains unusable, stop testing and collect
the kernel/QEMU logs. A host power cycle may be required. Do not add
`vendor-reset`, unsafe interrupts, ACS override, or a downloaded ROM as an
unreviewed first response.

For a WX 4100 passed to a Linux guest, `amdgpu.runpm=0` is a symptom-specific
guest workaround only when runtime-power transitions hang the virtual PCI bus
under load. It is not part of host preparation.

## Roll back the test

Stop the VM, then detach. The runner removes only its recorded `hostpciN` entry
and restores the exact prior virtual VGA value.

```bash
qm shutdown 101 --timeout 60
/tmp/proxmox-vm-gpu.sh --action detach --vm 101
```

Remove feature-owned host preparation and reboot to restore normal host-driver
ownership:

```bash
/tmp/proxmox-vm-gpu.sh \
  --action unprepare \
  --gpu 0000:18:00.0 \
  --yes \
  --reboot
```

`unprepare` refuses to run while a feature-owned VM attachment or any raw VM
reference to the GPU remains.

## Fact-check sources

The host and `qm` behavior follows the official [current Proxmox PCI(e)
passthrough guide](https://pve.proxmox.com/pve-docs/chapter-qm.html#qm_pci_passthrough),
the official [PVE 6 administration guide](https://pve.proxmox.com/pve-docs-6/pve-admin-guide.pdf),
and the official [bootloader/kernel-command-line guide](https://pve.proxmox.com/pve-docs/chapter-sysadmin.html#sysboot_edit_kernel_cmdline).
The selected-device implementation follows the Linux kernel's
[`driver_override` binding contract](https://www.kernel.org/doc/html/latest/driver-api/driver-model/binding.html):
set the override, unbind any current driver, load `vfio-pci`, and reprobe the
specific device.

Field notes remain explicitly secondary: Proxmox staff recommend passing the
[complete GPU including its audio function](https://forum.proxmox.com/threads/gpu-passthrough-issue-6-1-radeon-blank-screen.68821/),
and WX 4100 users report the Linux guest-only
[`amdgpu.runpm=0` workaround](https://forum.proxmox.com/threads/amd-rx-550-gpu-passthrough-issues.128405/)
for a specific runtime-power hang. The WX 4100/Baffin `67e3` compatibility note
for macOS comes from the [OpenCore GPU compatibility
table](https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/amd-gpu.html).
