# PVE 9 multi-AMD macOS acceptance runbook and evidence

This document records the manual remote-server acceptance sequence for one
observed PVE 9/Trixie node with five AMD Radeon Pro WX 4100 GPUs, a separate
Matrox management display, and macOS VM 100. It is test evidence and a worked
example, not a source of hardware defaults.

The observed environment is:

- Dry-run and failed-live-attempt SHA:
  `7af4063fae7b28cc2c2ebcc3b6956deeec9613f7`
- Proxmox VE: `9.2.10`
- Debian: `13` (`trixie`)
- Kernel: `7.0.14-11-pve`
- Bootloader: GRUB
- Host display: Matrox `0000:03:00.0` using `mgag200`
- Guest-dedicated AMD slots: `0000:18:00`, `0000:3b:00`, `0000:5e:00`,
  `0000:86:00`, and `0000:af:00`
- Trial GPU: `0000:3b:00.0`
- Trial VM: `100`
- Guest profile: `macos-desktop`

The dry run at that SHA passed, but its first live preparation failed while
rendering the optional legacy `vfio_virqfd` module and rolled back completely.
Do not retry a mutation with that SHA. Continue only with a subsequently
published SHA whose GitHub regression and Pages validation passed.

Re-run complete live inventory before reusing this procedure. Do not select a
GPU randomly in automation or assume that these BDFs identify the same devices
after a firmware, PCI topology, or hardware change. Every streamed mutation
uses an exact reviewed Pages candidate and `set -o pipefail`.

## Step 5 result

The explicit JSON dry run passed completely:

- All five AMD WX 4100 slots were selected.
- All ten display/audio PCI functions were included.
- The AMD vendor blacklist will be applied globally.
- Exact-BDF VFIO binding covers both `.0` and `.1` functions.
- The Matrox `0000:03:00.0` management GPU remains untouched.
- IOMMU isolation, PCI identity, assignment conflicts, collateral-display
  checks, and rollback planning passed.
- `state: dry-run` and `changes: []` confirm nothing was changed.

The accepted selection was:

```json
{
  "effective_vendors": ["amd"],
  "exact_bind_only_vendors": [],
  "affected_slots": [
    "0000:18:00",
    "0000:3b:00",
    "0000:5e:00",
    "0000:86:00",
    "0000:af:00"
  ],
  "affected_function_bdfs": [
    "0000:18:00.0",
    "0000:18:00.1",
    "0000:3b:00.0",
    "0000:3b:00.1",
    "0000:5e:00.0",
    "0000:5e:00.1",
    "0000:86:00.0",
    "0000:86:00.1",
    "0000:af:00.0",
    "0000:af:00.1"
  ]
}
```

For this trial, use the already-reviewed NUMA-0 GPU `0000:3b:00.0` for VM
100. Do not select a GPU randomly at command-execution time.

## Failed live attempt and rollback evidence

The first live preparation at `7af4063fae7b28cc2c2ebcc3b6956deeec9613f7`
reached the non-dry-run copy tasks, then failed because the PVE 9 release skips
the legacy `vfio_virqfd` probe. Ansible registered a skipped dictionary without
an `rc` member, while both inline templates attempted to read
`gpu_vfio_virqfd_probe.rc`.

The feature reported:

```text
result.state: failed-rolled-back
result.rollback_complete: true
result.message: Host preparation failed and original files were restored
```

The subsequent server audit confirmed:

- `/etc/ansible/proxmox/gpu-passthrough/host.state` is absent.
- The managed module list, initramfs hook, exact-BDF script, and AMD blacklist
  are all absent.
- `status` reports `prepared: false`, no configured GPUs, and `state: ok`.
- Transaction directory
  `/etc/ansible/proxmox/gpu-passthrough/transactions/20260818T060651-383514693`
  exists but is empty.

Preserve that empty directory as audit evidence. It does not conflict with the
unique transaction identifier created by a later retry. No reboot or manual
cleanup is required before testing the corrected candidate.

## 1. Select the corrected immutable candidate

Set the SHA only after its branch validation, Pages build, deployment, and
published-Pages validation succeed:

```bash
FEATURE_SHA='<published-fix-sha>'
GPU_URL="https://devs-guide.github.io/proxmox/setup/vm/gpu.sh?v=${FEATURE_SHA}"

printf '%s\n' "${GPU_URL}"
wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action status \
    --output json |
  jq '{facts, result}'

wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action inventory \
    --output json |
  jq .
```

The URL must remain on the same shell command line as `wget -qO-`, and the pipe
before `bash` is mandatory. Set `FEATURE_SHA` and `GPU_URL` again after every
reconnect or reboot. Stop if raw inventory is not a JSON object with
`.inventory.gpus`.

## 2. Make the AMD blacklist and VFIO binding live

This mutates host configuration but deliberately does not reboot
automatically:

```bash
set -o pipefail

wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action prepare \
    --binding early \
    --blacklist '{"amd":["0000:18:00.0","0000:3b:00.0","0000:5e:00.0","0000:86:00.0","0000:af:00.0"]}' \
    --allow-host-display-loss \
    --yes \
    --output json |
  tee /root/proxmox-gpu-prepare-live.json |
  jq .
```

Require:

```text
result.state: prepared
result.rollback_complete: true
result.message contains: reboot_required=True
```

Do not reboot if the command reports `failed-rolled-back` or
`failed-rollback-incomplete`. Preserve its result and transaction directory for
review.

Inspect the committed format-4 state and every managed host file:

```bash
jq '{
  format,
  gpu_slots,
  gpu_functions,
  blacklist_vendors,
  exact_bind_only_vendors,
  binding_strategy
}' /etc/ansible/proxmox/gpu-passthrough/host.state

sed -n '1,120p' \
  /etc/modules-load.d/proxmox-gpu-passthrough.conf
sed -n '1,120p' \
  /etc/initramfs-tools/hooks/proxmox-gpu-passthrough
sed -n '1,200p' \
  /etc/initramfs-tools/scripts/init-top/proxmox-gpu-passthrough
sed -n '1,120p' \
  /etc/modprobe.d/proxmox-gpu-passthrough-blacklist.conf
```

Expected:
- `format: 4`
- Five AMD slots and ten functions
- `blacklist_vendors: ["amd"]`
- `exact_bind_only_vendors: []`
- `binding_strategy: early`
- The blacklist contains `amdgpu` and `radeon`
- The exact-BDF script contains all ten AMD functions
- No managed file selects Matrox `0000:03:00.0`

Then reboot:

```bash
sync
reboot
```

## 3. Verify all AMD functions after reboot

After reconnecting, run the host-wide state-aware verification. Format-4 state
provides the complete selection when `--gpu` is omitted:

```bash
FEATURE_SHA='<same-published-fix-sha>'
GPU_URL="https://devs-guide.github.io/proxmox/setup/vm/gpu.sh?v=${FEATURE_SHA}"

wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action verify \
    --output json |
  jq .
```

Expected result fragment:

```json
{
  "effective_features": {
    "binding": "early"
  },
  "result": {
    "state": "ready",
    "ready": true
  }
}
```

Inspect live ownership:

```bash
wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action inventory \
    --output json |
  jq '[.inventory.gpus[] | {
    slot,
    boot_vga,
    functions: [.functions[] | {bdf, driver}]
  }]'
```

All ten AMD functions must report `vfio-pci`. The Matrox GPU must remain on
`mgag200`.

Also review boot errors:

```bash
journalctl -b -k --no-pager |
  grep -Ei 'vfio|iommu|amd-vi|dmar|bar|reset|aer' || true
```

Stop if there are fatal VFIO, BAR-allocation, IOMMU, or AER errors.

## 4. Revalidate VM 100 and preview attachment

```bash
qm status 100
qm config 100
```

VM 100 must be stopped, with no existing `hostpci0`. Run post-reboot
preflight:

```bash
wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action preflight \
    --vm 100 \
    --gpu 0000:3b:00.0 \
    --profile macos-desktop \
    --binding early \
    --hostpci-index 0 \
    --primary-gpu \
    --allow-guest-console-loss \
    --yes \
    --output json |
  jq .
```

Then preview the attachment:

```bash
wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action attach \
    --vm 100 \
    --gpu 0000:3b:00.0 \
    --profile macos-desktop \
    --binding early \
    --hostpci-index 0 \
    --primary-gpu \
    --allow-guest-console-loss \
    --disable-onboot \
    --yes \
    --dry-run \
    --output json |
  jq .
```

Require `result.state: dry-run` and a proposed `hostpci0` attachment.

## 5. Attach without starting the VM

Run the mutation through the same published candidate without starting the VM:

```bash
set -o pipefail

wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action attach \
    --vm 100 \
    --gpu 0000:3b:00.0 \
    --profile macos-desktop \
    --binding early \
    --hostpci-index 0 \
    --primary-gpu \
    --allow-guest-console-loss \
    --disable-onboot \
    --yes \
    --output json |
  tee /root/proxmox-gpu-attach-vm100.json |
  jq .
```

Inspect before starting:

```bash
qm config 100
```

Expected configuration:

```text
hostpci0: 0000:3b:00,pcie=1,x-vga=1
vga: none
onboot: 0
```

## 6. Start and verify host-side passthrough

Ensure guest SSH, a physical GPU display, or another guest-access method is
available because the Proxmox virtual console is disabled.

```bash
qm start 100
qm status 100
```

Run state-aware verification while the VM is running:

```bash
wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action verify \
    --vm 100 \
    --gpu 0000:3b:00.0 \
    --profile macos-desktop \
    --binding early \
    --output json |
  jq .
```

Collect host evidence:

```bash
lspci -Dnnk -s 0000:3b:00.0
lspci -Dnnk -s 0000:3b:00.1

journalctl -b -k --no-pager |
  grep -Ei 'vfio|0000:3b:00|bar|reset|aer|iommu' || true
```

Both functions must remain owned by `vfio-pci`.

## 7. Confirm Metal acceleration inside macOS

Run these commands inside VM 100, not on the Proxmox host:

```bash
system_profiler SPDisplaysDataType
ioreg -r -c IOAccelerator -l
```

Acceptance requires:

- The AMD GPU is detected with the expected VRAM.
- `Metal: Supported` is reported.
- An `IOAccelerator` device exists.
- The display is driven by the passed-through GPU.

If Xcode command-line tools are already present, submit a Metal command buffer:

```bash
xcrun swift - <<'SWIFT'
import Metal

if let device = MTLCreateSystemDefaultDevice(),
   let queue = device.makeCommandQueue(),
   let command = queue.makeCommandBuffer() {
    command.commit()
    command.waitUntilCompleted()
    precondition(command.status == .completed)
    print("Metal command completed on: \(device.name)")
} else {
    fatalError("No usable Metal device")
}
SWIFT
```

The registration and command-buffer checks are smoke tests. Run a real Metal
render or compute workload before accepting full acceleration.

Complete at least three controlled guest shutdown/start cycles. After each
start, repeat the workload and review the host log:

```bash
qm shutdown 100 --timeout 120
qm status 100
qm start 100
qm status 100

journalctl -b -k --no-pager |
  grep -Ei 'vfio|0000:3b:00|bar|reset|aer|iommu' || true
```

The audio functions in this observed topology reported no reset support. If a
subsequent start fails, stop and preserve the guest and host logs. Do not add an
unreviewed reset workaround. A controlled host power cycle may be required to
recover a non-resetting GPU.

The trial is accepted only after host-wide VFIO verification, feature-owned VM
attachment, successful guest Metal workload execution, and all three reset
cycles complete without fatal errors.
