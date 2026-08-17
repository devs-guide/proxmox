# Proxmox whole-GPU passthrough runbook

This runbook covers the repository-supported lanes: Proxmox VE 6.4 on Buster
and Proxmox VE 9.x on Trixie. The public runner is `setup/vm/gpu.sh`; it
dispatches read-only work to `cli/gpu/inspect.sh` and mutations to the selected
release playbook through `cli/gpu/apply.sh`.

Run commands on the Proxmox node as `root`. Keep tested SSH and out-of-band
console access before changing GPU ownership or boot configuration.

## Scope and safety

The feature supports an AMD or NVIDIA GPU in one node-local PCI slot and all
same-slot functions, such as graphics, audio, USB, and UCSI. It supports stopped,
non-HA QEMU VMs using Q35. Desktop profiles also require OVMF and an EFI disk.

It does not configure ACS override, unsafe interrupts, ROM files, SR-IOV,
mediated devices, guest drivers, resource mappings, live migration, or GPU reset
workarounds. It refuses PVE 7 and PVE 8 rather than guessing across an untested
release lane.

The feature never binds by shared vendor/device ID. Early binding uses exact PCI
addresses. Optional blacklisting is vendor-specific and is refused if another
unselected display GPU uses the same driver family.

## Release behavior

| Detected host | Release lane | Default binding | Normal workflow |
| --- | --- | --- | --- |
| PVE 6 + Buster | `6.4` | `early` | prepare, reboot, verify, attach |
| PVE 9 + Trixie | `9.1` | `automatic` | preflight, attach; prepare only when needed |

PVE 6 requires exact-BDF VFIO ownership before attachment. The playbook adds the
available legacy VFIO module only when `modinfo vfio_virqfd` succeeds and uses
GRUB, `pve-efiboot-tool`, or `proxmox-boot-tool` according to the live node.

PVE 9 starts with automatic Proxmox device handoff. A native driver while the VM
is stopped is not itself a failure. Use `--binding early` only after automatic
handoff has demonstrably failed. Neither lane adds `amd_iommu=on`; on Intel,
`intel_iommu=on` is added only when live IOMMU groups are absent. `iommu=pt` is
opt-in through `--iommu-pt`.

Live platform detection is always authoritative. The platform helper records
the complete `pveversion`, Debian codename, kernel, boot tooling, and adapter
capabilities before selecting a release wrapper. `--release 6.4` and
`--release 9.1` are optional assertions: they can reject a mismatch but can
never select or override tooling. Compatible future PVE 9 minors continue
through the PVE 9/Trixie capability adapter; unknown or cross-matched platforms
fail closed.

## Action contract

| Action | Mutates | Required values | Purpose |
| --- | --- | --- | --- |
| `inventory` | no | none | list GPU slots, vendor, driver, and boot-VGA state |
| `preflight` | no | `--gpu`; optional `--vm` | validate identity, full slot, IOMMU isolation, conflicts, and VM eligibility |
| `prepare` | yes | `--gpu`, `--yes` | apply only requested release-specific host preparation |
| `verify` / `--test` | no | `--gpu`; optional `--vm` | state-aware readiness check after preparation or reboot |
| `attach` / `--attach` | yes | `--vm`, `--gpu`, `--yes` | add the whole slot to one stopped VM |
| `detach` / `--remove` | yes | `--vm`, `--yes` | remove only the feature-owned `hostpciN` entry and restore managed VM fields |
| `status` | no | none | report managed host state and optional live function state |
| `unprepare` | yes | `--yes` | restore exact host files after all attachments are removed |

Every mutating action accepts `--dry-run` instead of `--yes`. Inputs are
noninteractive and therefore safe for remote automation. Use `--output json`
for stable schema-v3 result documents containing `platform`, `adapter`, the
complete `inventory`, and an explicit `selection` for targeted actions.

## Feature flags

- `--binding release|automatic|early` uses the detected adapter capability or
  an explicit supported strategy. PVE 6 refuses `automatic`.
- `--blacklist` and `--blacklist-host-drivers` are aliases valid only for
  `prepare`. They require `--allow-host-display-loss --yes`.
- `--primary-gpu` adds `x-vga=1` and changes `vga` to `none`. It requires
  `--allow-guest-console-loss --yes` for a real attachment.
- `--disable-onboot` changes `onboot` to `0` during commissioning and records
  the exact prior value for detach.
- `--start` starts the VM only after a successful attachment transaction.
- `--iommu-pt` requests the optional `iommu=pt` kernel token.
- `--reboot` reboots only after successful `prepare` or `unprepare`.
- `--hostpci-index auto|0..15` defaults to the first unused entry.

Profiles are `macos-desktop`, `windows-desktop`, `linux-desktop`, and
`linux-compute`. Compatibility aliases `macos`, `winos`, `linux`, and `compute`
are accepted. A desktop profile validates OVMF/EFI requirements; it does not
implicitly remove the virtual console. Use `--primary-gpu` for that explicit
change. The macOS profile rejects NVIDIA hardware.

## Obtain a coherent review candidate

Do not run the raw feature-branch bootstrap against stale Pages dependencies.
After human review, commit and push the complete candidate, then publish its
exact SHA through the trusted workflow described in
`prompt/core/publish.feature.script.plan`. That workflow replaces the complete
Pages snapshot so the runner, CLI helpers, release wrappers, and shared
playbook remain coherent.

Download before executing—even for a dry-run mutation:

```bash
install -d -m 0700 /root/proxmox-gpu-review
curl -fsSL \
  https://devs-guide.github.io/proxmox/setup/vm/gpu.sh \
  -o /root/proxmox-gpu-review/gpu.sh
chmod 0755 /root/proxmox-gpu-review/gpu.sh
bash -n /root/proxmox-gpu-review/gpu.sh
sha256sum /root/proxmox-gpu-review/gpu.sh
sed -n '1,220p' /root/proxmox-gpu-review/gpu.sh
```

Record the feature SHA, workflow run, Pages deployment commit, runner checksum,
node, PVE version, kernel, GPU slot, VM ID, and rollback result in the review.

For a complete observed acceptance case covering an unmanaged primary-GPU
replacement, both read-only primary confirmation forms, expected blacklist
refusal, automatic attach preview, and feature-owned final attachment, see
[`examples.md`](examples.md#manual-pve-9-primary-gpu-replacement-acceptance-scenario).

## 1. Inventory and inspect

```bash
GPU_RUNNER=/root/proxmox-gpu-review/gpu.sh

"${GPU_RUNNER}" --action inventory --output json \
  | tee /root/proxmox-gpu-review/inventory.json

jq -r '.platform, .adapter, .inventory.gpus[]' \
  /root/proxmox-gpu-review/inventory.json
```

Do not select `.inventory.gpus[0]` or assume a worked-example address. A human
must choose an exact display-function BDF from `display_bdfs`, then choose an
eligible stopped VM and profile:

```bash
read -r -p 'Exact display-function BDF: ' GPU_BDF
read -r -p 'Stopped Q35 VMID: ' VM_ID
read -r -p \
  'Profile (macos-desktop/windows-desktop/linux-desktop/linux-compute): ' \
  GPU_PROFILE

lspci -Dnnk -s "${GPU_BDF}"
qm status "${VM_ID}"
qm config "${VM_ID}"
```

Confirm that the selected slot is dedicated, does not contain a management or
storage device, is not already assigned, and is recoverable through another
console. A shortened function-qualified address such as `18:00.0` normalizes
to `0000:18:00.0`; slot-only input such as `18:00` is rejected.

## 2. Run read-only preflight

```bash
"${GPU_RUNNER}" \
  --action preflight \
  --vm "${VM_ID}" \
  --gpu "${GPU_BDF}" \
  --profile "${GPU_PROFILE}" \
  --output json
```

Preflight refuses a running, locked, template, HA-managed, or non-Q35 VM; an
unsupported GPU; an unrelated endpoint in an IOMMU group; a boot GPU without
acknowledgement; an occupied `hostpciN`; and references from other VMs.

## 3A. PVE 9 automatic path

When IOMMU groups exist and preflight passes, preview and attach without host
preparation:

```bash
"${GPU_RUNNER}" \
  --action attach \
  --vm "${VM_ID}" \
  --gpu "${GPU_BDF}" \
  --profile "${GPU_PROFILE}" \
  --dry-run \
  --output json

"${GPU_RUNNER}" \
  --action attach \
  --vm "${VM_ID}" \
  --gpu "${GPU_BDF}" \
  --profile "${GPU_PROFILE}" \
  --yes
```

If automatic handoff fails, detach any partial manual configuration, collect
the QEMU and kernel errors, and review the early-binding path. Do not jump
directly to global blacklisting.

## 3B. PVE 6 or explicit early binding

Preview host preparation:

```bash
"${GPU_RUNNER}" \
  --action prepare \
  --gpu "${GPU_BDF}" \
  --binding early \
  --dry-run \
  --output json
```

Apply, then reboot explicitly or with `--reboot`:

```bash
"${GPU_RUNNER}" \
  --action prepare \
  --gpu "${GPU_BDF}" \
  --binding early \
  --yes \
  --reboot
```

Preparation backs up every managed path under the root-only state directory,
installs exact-BDF initramfs binding, refreshes the active boot mechanism, and
rebuilds initramfs. A failed transaction restores its original files and
refreshes boot artifacts before reporting whether rollback completed.

Use vendor blacklisting only after a reviewed failure proves it necessary:

```bash
"${GPU_RUNNER}" \
  --action prepare \
  --gpu "${GPU_BDF}" \
  --binding early \
  --blacklist \
  --allow-host-display-loss \
  --yes \
  --dry-run
```

The request is refused if another unselected display GPU has the same vendor.

## 4. Verify and attach

After an early-binding reboot:

```bash
"${GPU_RUNNER}" \
  --test \
  --vm "${VM_ID}" \
  --gpu "${GPU_BDF}" \
  --profile "${GPU_PROFILE}" \
  --output json
```

For a primary guest display, preview and apply the explicit console change:

```bash
"${GPU_RUNNER}" \
  --attach \
  --vm "${VM_ID}" \
  --gpu "${GPU_BDF}" \
  --profile "${GPU_PROFILE}" \
  --primary-gpu \
  --allow-guest-console-loss \
  --disable-onboot \
  --dry-run

"${GPU_RUNNER}" \
  --attach \
  --vm "${VM_ID}" \
  --gpu "${GPU_BDF}" \
  --profile "${GPU_PROFILE}" \
  --primary-gpu \
  --allow-guest-console-loss \
  --disable-onboot \
  --yes
```

Inspect `qm config "${VM_ID}"` before starting. Add `--start` only when an immediate
start is intentional.

## 5. Exercise stop/start and collect evidence

Verify the device in the guest, shut the guest down cleanly, and perform one
controlled second start. A GPU that cannot reset may require a host power cycle.
Stop and collect logs rather than adding an unreviewed reset workaround.

```bash
qm shutdown "${VM_ID}" --timeout 60
qm status "${VM_ID}"
qm start "${VM_ID}"
journalctl -b -k | grep -Ei 'vfio|reset|BAR|IOMMU'
```

## Rollback

Stop the VM. Detach requires feature-owned state and removes only its recorded
entry; it restores the exact prior `vga` and managed `onboot` values.

```bash
qm shutdown "${VM_ID}" --timeout 60
"${GPU_RUNNER}" --remove --vm "${VM_ID}" --dry-run
"${GPU_RUNNER}" --remove --vm "${VM_ID}" --yes
```

After all owned attachments are gone, preview and restore host configuration:

```bash
"${GPU_RUNNER}" --action unprepare --dry-run
"${GPU_RUNNER}" --action unprepare --yes --reboot
```

Unprepare refuses raw VM references, bootloader drift, missing backups, and a
GPU slot that differs from owned state. Detach and unprepare can recover from
state even when the physical device is temporarily absent.

## State and recovery

State lives under `/etc/ansible/proxmox/gpu-passthrough/` with mode `0700`;
state documents use mode `0600`. Schema-v3 state records the exact selected
display BDF, every function identity record, release adapter, bootloader,
binding strategy, original file existence, checksums, and backups. When
hardware is absent, detach/unprepare requires those exact identity records.
Incomplete legacy state is accepted only when live inventory plus an explicit
function-qualified `--gpu` can prove the selection; the runner never invents a
`.0` function.

Do not edit or delete state while an attachment exists. On a failed operation,
retain the result JSON, transaction directory, state files, `qm config`, boot
files, and logs for review.

## References

- [Current Proxmox PCI(e) passthrough guide](https://pve.proxmox.com/pve-docs/chapter-qm.html#qm_pci_passthrough)
- [PVE 6 administration guide](https://pve.proxmox.com/pve-docs-6/pve-admin-guide.pdf)
- [Proxmox bootloader and kernel command line](https://pve.proxmox.com/pve-docs/chapter-sysadmin.html#sysboot_edit_kernel_cmdline)
- [Linux driver override binding contract](https://www.kernel.org/doc/html/latest/driver-api/driver-model/binding.html)
