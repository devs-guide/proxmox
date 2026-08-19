# GPU runner examples

These examples use a downloaded and reviewed Pages candidate. Do not stream a
mutating action into `bash`.

For a complete first-use sequence, hardened `wget` download flags, checksum
verification, and release-specific rollback, use:

- [PVE 6.4 / Buster GPU passthrough](pve-6.4.md)
- [PVE 9.1 / Trixie GPU passthrough](pve-9.1.md)

```bash
GPU_URL='https://devs-guide.github.io/proxmox/setup/vm/gpu.sh'
GPU_RUNNER='/root/proxmox-gpu-review/gpu.sh'

install -d -m 0700 /root/proxmox-gpu-review
curl -fsSL "${GPU_URL}" -o "${GPU_RUNNER}"
chmod 0755 "${GPU_RUNNER}"
bash -n "${GPU_RUNNER}"
sha256sum "${GPU_RUNNER}"
```

Read-only discovery:

```bash
"${GPU_RUNNER}" --action inventory --output json \
  | tee /root/proxmox-gpu-review/inventory.json

read -r -p 'Exact inventory display BDF (no default): ' GPU_BDF
read -r -p 'Stopped Q35 VMID (no default): ' VM_ID
read -r -p 'Guest profile (no default): ' GPU_PROFILE

"${GPU_RUNNER}" --action status --gpu "${GPU_BDF}" --output json
"${GPU_RUNNER}" --action preflight \
  --vm "${VM_ID}" --gpu "${GPU_BDF}" --profile "${GPU_PROFILE}" \
  --output json
```

The values must be copied from complete live inventory and VM inspection.
Never select the first JSON entry automatically. The examples below reuse
those reviewed variables; they do not define a GPU, VM, profile, or release
default.

PVE 9 automatic attachment preview and apply:

```bash
"${GPU_RUNNER}" --attach \
  --vm "${VM_ID}" --gpu "${GPU_BDF}" --profile "${GPU_PROFILE}" --dry-run
"${GPU_RUNNER}" --attach \
  --vm "${VM_ID}" --gpu "${GPU_BDF}" --profile "${GPU_PROFILE}" --yes
```

PVE 6 early-binding preparation, post-reboot verification, and attachment:

```bash
"${GPU_RUNNER}" --action prepare \
  --gpu "${GPU_BDF}" --binding early --dry-run
"${GPU_RUNNER}" --action prepare \
  --gpu "${GPU_BDF}" --binding early --yes --reboot

"${GPU_RUNNER}" --test \
  --vm "${VM_ID}" --gpu "${GPU_BDF}" --profile "${GPU_PROFILE}" \
  --output json
"${GPU_RUNNER}" --attach \
  --vm "${VM_ID}" --gpu "${GPU_BDF}" --profile "${GPU_PROFILE}" \
  --yes
```

Explicit primary-display attachment:

```bash
"${GPU_RUNNER}" --attach \
  --vm "${VM_ID}" \
  --gpu "${GPU_BDF}" \
  --profile "${GPU_PROFILE}" \
  --primary-gpu \
  --allow-guest-console-loss \
  --disable-onboot \
  --hostpci-index auto \
  --yes
```

Last-resort, vendor-specific blacklist preview:

```bash
"${GPU_RUNNER}" --action prepare \
  --binding early \
  --blacklist-amd \
  --allow-host-display-loss \
  --yes \
  --dry-run
```

Detach and host rollback:

```bash
qm shutdown "${VM_ID}" --timeout 60
"${GPU_RUNNER}" --remove --vm "${VM_ID}" --dry-run
"${GPU_RUNNER}" --remove --vm "${VM_ID}" --yes

"${GPU_RUNNER}" --action unprepare --dry-run
"${GPU_RUNNER}" --action unprepare --yes --reboot
```

Use `--output json` on any action that needs a machine-readable result. Live
platform detection always chooses tooling. An explicit `--release` is an
assertion only and, if supplied, must match the detected adapter.

## Manual PVE 9 primary-GPU replacement acceptance scenario

This example records the complete manual test discovered on a PVE 9/Trixie
node with several identical AMD GPUs. The identifiers are example topology,
not defaults. Re-run inventory and replace every value before using the
scenario on another node.

The node-specific five-WX-4100 early-binding, rollback, and macOS acceptance
evidence is preserved in
[`pve9-multi-amd-macos-acceptance.md`](pve9-multi-amd-macos-acceptance.md).

Set one reviewed Pages candidate URL on a single line:

```bash
FEATURE_SHA='<full published feature SHA>'
GPU_URL="https://devs-guide.github.io/proxmox/setup/vm/gpu.sh?v=${FEATURE_SHA}"
VM_ID=100
OLD_GPU_BDF='0000:18:00.0'
GPU_BDF='0000:3b:00.0'
GPU_PROFILE='macos-desktop'
```

### Remove an unmanaged primary-GPU assignment

Use this manual cleanup only when `status` reports `prepared:false`, no
feature-owned VM state exists, the VM is stopped, and the existing `hostpci`
entry was created outside this runner. Back up the exact VM configuration,
remove the old PCI entry, and remove the explicit `vga:none` primary-display
setting:

```bash
qm status "${VM_ID}"
cp -a \
  "/etc/pve/qemu-server/${VM_ID}.conf" \
  "/root/vm-${VM_ID}.before-gpu-swap.conf"

qm set "${VM_ID}" --delete hostpci0
qm set "${VM_ID}" --delete vga
qm config "${VM_ID}"
```

Do not continue if `hostpci0` or `vga:none` remains. Confirm through fresh
inventory that the old GPU is no longer assigned:

```bash
wget -qO- "${GPU_URL}" |
  bash -s -- --action inventory --output json |
  jq --arg slot "${OLD_GPU_BDF%.*}" \
    '.inventory.gpus[] | select(.slot == $slot)'
```

### Validate the replacement and primary-display intent

Run hardware-only preflight first:

```bash
wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action preflight \
    --gpu "${GPU_BDF}" \
    --profile "${GPU_PROFILE}" \
    --output json |
  jq .
```

The current primary-GPU confirmation gate accepts either of the following
read-only preflight forms. The explicit acknowledgement form mirrors the later
real attachment. `--yes` cannot dispatch a mutation while the action remains
`preflight`:

```bash
wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action preflight \
    --vm "${VM_ID}" \
    --gpu "${GPU_BDF}" \
    --profile "${GPU_PROFILE}" \
    --hostpci-index 0 \
    --primary-gpu \
    --allow-guest-console-loss \
    --yes \
    --output json |
  jq .
```

Alternatively, `--dry-run` satisfies the confirmation gate while preflight
remains read-only:

```bash
wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action preflight \
    --vm "${VM_ID}" \
    --gpu "${GPU_BDF}" \
    --profile "${GPU_PROFILE}" \
    --hostpci-index 0 \
    --primary-gpu \
    --dry-run \
    --output json |
  jq .
```

Require `result.ready == true`, `binding == "automatic"`, the reviewed VMID,
and both functions from the selected GPU slot before continuing.

### Exercise the vendor-blacklist refusal

When multiple unselected display GPUs use the same AMD or NVIDIA driver
family, vendor blacklisting is intentionally unavailable. This command tests
that safety gate without changing the host:

```bash
wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action prepare \
    --gpu "${GPU_BDF}" \
    --binding early \
    --blacklist \
    --allow-host-display-loss \
    --yes \
    --dry-run \
    --output json |
  jq .
```

The deprecated bare form still refuses collateral capture and should list the
other AMD display GPUs. Never remove `--dry-run` merely to bypass that refusal.

Preview a complete AMD host set with the supported multi-GPU interface:

```bash
wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action prepare \
    --binding early \
    --blacklist-amd \
    --allow-host-display-loss \
    --yes \
    --dry-run \
    --output json |
  jq .
```

The streamed command resolves `/opt/ansible-venv/bin/ansible-playbook`
directly. Do not prepend the managed venv to `PATH`; if the canonical runtime is
missing or outside version policy, repair it through the matching release
bootstrap before continuing.

For an explicit partial set, use JSON. The result must report AMD under
`exact_bind_only_vendors`, not `effective_vendors`:

```bash
wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action prepare \
    --binding early \
    --blacklist '{"amd":["0000:3b:00.0"]}' \
    --allow-host-display-loss \
    --yes \
    --dry-run \
    --output json |
  jq .
```

### Preview and apply automatic primary-GPU attachment

PVE 9 automatic handoff is the first attachment path. Preview it directly from
the reviewed Pages snapshot:

```bash
wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action attach \
    --vm "${VM_ID}" \
    --gpu "${GPU_BDF}" \
    --profile "${GPU_PROFILE}" \
    --binding automatic \
    --hostpci-index 0 \
    --primary-gpu \
    --disable-onboot \
    --dry-run \
    --output json |
  jq .
```

Review the complete dry-run result. Download and inspect the same immutable
candidate before the real mutation; do not stream a mutating action:

```bash
GPU_RUNNER='/root/proxmox-gpu-review/gpu.sh'
install -d -m 0700 /root/proxmox-gpu-review
wget -qO "${GPU_RUNNER}" "${GPU_URL}"
chmod 0755 "${GPU_RUNNER}"
bash -n "${GPU_RUNNER}"
sed -n '1,220p' "${GPU_RUNNER}"

"${GPU_RUNNER}" \
  --action attach \
  --vm "${VM_ID}" \
  --gpu "${GPU_BDF}" \
  --profile "${GPU_PROFILE}" \
  --binding automatic \
  --hostpci-index 0 \
  --primary-gpu \
  --allow-guest-console-loss \
  --disable-onboot \
  --yes
```

Do not add `--start` during commissioning. Verify that the selected whole slot
is now assigned through feature-owned state:

```bash
qm config "${VM_ID}"

wget -qO- "${GPU_URL}" |
  bash -s -- \
    --action status \
    --gpu "${GPU_BDF}" \
    --output json |
  jq .
```

The expected VM fields are `hostpci0: 0000:3b:00,pcie=1,x-vga=1` and
`vga: none`. If automatic attachment fails, stop and preserve the error before
reviewing exact-BDF early preparation. Do not substitute a global driver
blacklist.

The exceptional all-AMD early-binding continuation, including the failed-live
rollback record, corrected streamed retry, reboot verification, VM 100
attachment, Metal workload, and reset-cycle gates, is maintained only in the
dedicated acceptance runbook linked above.
