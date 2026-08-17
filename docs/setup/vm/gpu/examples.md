# GPU runner examples

These examples use a downloaded and reviewed Pages candidate. Do not stream a
mutating action into `bash`.

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
  --gpu "${GPU_BDF}" \
  --binding early \
  --blacklist \
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
