# PVE 6.4 / Buster GPU passthrough runbook

This is the operator runbook for the repository-supported Proxmox VE 6.4 on
Debian Buster lane. PVE 6 uses exact-address early VFIO binding, so the normal
sequence is `prepare`, reboot, `verify`, `attach`, guest testing, `--remove`,
`unprepare`, and a final reboot.

Run every command as `root` on the Proxmox node. Keep a tested SSH session and
working out-of-band console before changing boot configuration or GPU driver
ownership. Stop if live detection does not report the `6.4` adapter; the
`--release 6.4` option below is an assertion and cannot override the detected
platform.

## Safety boundary

Use a stopped, non-template, non-HA Q35 VM. Desktop profiles additionally need
OVMF and an EFI disk. Do not select the controller for the PVE boot disk, the
only management NIC, a required PCI bridge, or the only usable host display.
Do not proceed if the selected IOMMU group contains an unrelated endpoint.

The runner does not configure ACS override, unsafe interrupts, ROM files,
mediated devices, guest drivers, or reset workarounds. A real vendor blacklist
can remove every matching host GPU from its native driver. It is a last-resort
operation and requires out-of-band access.

Do not stream a mutating action through `wget | bash`. Download and verify the
complete candidate first.

## 1. Record the node and runtime

```bash
set -o pipefail

install -d -m 0700 /root/proxmox-gpu-evidence
pveversion --verbose | tee /root/proxmox-gpu-evidence/pveversion.txt
cat /etc/os-release | tee /root/proxmox-gpu-evidence/os-release.txt
uname -a | tee /root/proxmox-gpu-evidence/uname.txt
cat /proc/cmdline | tee /root/proxmox-gpu-evidence/proc-cmdline.txt
proxmox-boot-tool status 2>&1 \
  | tee /root/proxmox-gpu-evidence/proxmox-boot-tool.txt || true
```

Require Buster and the managed Ansible runtime pinned by the repository:

```bash
grep -Eq '^VERSION_CODENAME=?"?buster"?$' /etc/os-release
pveversion | grep -Eq '^pve-manager/6\.'

for command_name in bash jq lspci qm pveversion flock sha256sum wget; do
  command -v "${command_name}" >/dev/null || {
    echo "missing prerequisite: ${command_name}" >&2
    exit 1
  }
done

test -x /opt/ansible-venv/bin/ansible-playbook
/opt/ansible-venv/bin/ansible-playbook --version | sed -n '1p'
test "$(/opt/ansible-venv/bin/ansible-playbook --version | sed -n '1p')" = \
  'ansible-playbook [core 2.20.5]'
```

If the managed runtime is absent or out of policy, stop and repair it through
the separately reviewed PVE 6 bootstrap. Do not install an arbitrary system
Ansible for this test. Its public bootstrap URL is
`https://devs-guide.github.io/proxmox/6.4.sh`; running that bootstrap is a
separate host-provisioning decision because it also manages Buster repositories
and the release playlist.

## 2. Download the exact published candidate

Set the full SHA from the successful trusted Pages workflow. The query value is
a cache buster; it does not select a Git branch.

```bash
FEATURE_SHA='<full-40-character-published-feature-sha>'
PAGES_BASE='https://devs-guide.github.io/proxmox'
REVIEW_ROOT='/root/proxmox-gpu-review'

[[ "${FEATURE_SHA}" =~ ^[0-9a-f]{40}$ ]]
umask 077
install -d -m 0700 "${REVIEW_ROOT}"

fetch_page_file() {
  remote_path="$1"
  local_path="$2"
  file_mode="$3"
  destination="${REVIEW_ROOT}/${local_path}"
  temporary="${destination}.download"

  install -d -m 0700 "$(dirname "${destination}")"
  wget \
    --https-only \
    --secure-protocol=TLSv1_2 \
    --dns-timeout=15 \
    --connect-timeout=15 \
    --read-timeout=30 \
    --timeout=30 \
    --tries=3 \
    --waitretry=2 \
    --retry-connrefused \
    --header='Cache-Control: no-cache' \
    -O "${temporary}" \
    "${PAGES_BASE}/${remote_path}?v=${FEATURE_SHA}"
  test -s "${temporary}"
  mv -f "${temporary}" "${destination}"
  chmod "${file_mode}" "${destination}"
}

while IFS='|' read -r remote_path local_path file_mode; do
  fetch_page_file "${remote_path}" "${local_path}" "${file_mode}"
done <<'FILES'
setup/vm/gpu.sh|setup/vm/gpu.sh|0755
ansible.runtime.sh|bootstrap/ansible.runtime.sh|0644
cli/gpu/platform.sh|cli/gpu/platform.sh|0644
cli/gpu/inventory.sh|cli/gpu/inventory.sh|0644
cli/gpu/common.sh|cli/gpu/common.sh|0644
cli/gpu/inspect.sh|cli/gpu/inspect.sh|0755
cli/gpu/apply.sh|cli/gpu/apply.sh|0755
ansible/release/6.4/gpu.yml|ansible/release/6.4/gpu.yml|0644
ansible/release/9.1/gpu.yml|ansible/release/9.1/gpu.yml|0644
ansible/proxmox/helper/vm.gpu.yml|ansible/proxmox/helper/vm.gpu.yml|0644
FILES
```

Both release wrappers are part of the declared bootstrap closure even though
live detection will select only PVE 6. Check syntax and compare the complete
tree with the checksum manifest generated from the exact feature commit:

```bash
bash -n \
  "${REVIEW_ROOT}/setup/vm/gpu.sh" \
  "${REVIEW_ROOT}/bootstrap/ansible.runtime.sh" \
  "${REVIEW_ROOT}/cli/gpu/platform.sh" \
  "${REVIEW_ROOT}/cli/gpu/inventory.sh" \
  "${REVIEW_ROOT}/cli/gpu/common.sh" \
  "${REVIEW_ROOT}/cli/gpu/inspect.sh" \
  "${REVIEW_ROOT}/cli/gpu/apply.sh"

(cd "${REVIEW_ROOT}" && sha256sum \
  setup/vm/gpu.sh \
  bootstrap/ansible.runtime.sh \
  cli/gpu/platform.sh \
  cli/gpu/inventory.sh \
  cli/gpu/common.sh \
  cli/gpu/inspect.sh \
  cli/gpu/apply.sh \
  ansible/release/6.4/gpu.yml \
  ansible/release/9.1/gpu.yml \
  ansible/proxmox/helper/vm.gpu.yml) \
  | tee "/root/proxmox-gpu-evidence/${FEATURE_SHA}.observed.sha256"

EXPECTED_MANIFEST="/root/proxmox-gpu-evidence/${FEATURE_SHA}.expected.sha256"
test -r "${EXPECTED_MANIFEST}"
(cd "${REVIEW_ROOT}" && sha256sum -c "${EXPECTED_MANIFEST}")

sed -n '1,220p' "${REVIEW_ROOT}/setup/vm/gpu.sh"
```

Do not continue until a reviewer has compared those hashes with the exact Git
commit or workflow artifact. Running the bootstrap from this repository-shaped
tree keeps every dependency local for the duration of the test.

```bash
GPU_RUNNER="${REVIEW_ROOT}/setup/vm/gpu.sh"
```

The immutable public copy of this document is:

```text
https://raw.githubusercontent.com/devs-guide/proxmox/<FEATURE_SHA>/docs/setup/vm/gpu/pve-6.4.md
```

After the exact candidate is live, this streamed form is permitted only for a
read-only reachability/inventory check. It is not a substitute for downloading
and hashing the complete closure before any dry-run or mutation:

```bash
wget --https-only --secure-protocol=TLSv1_2 --timeout=30 --tries=3 \
  --header='Cache-Control: no-cache' \
  -O- "${PAGES_BASE}/setup/vm/gpu.sh?v=${FEATURE_SHA}" \
  | bash -s -- --action inventory --release 6.4 --output json
```

## 3. Inventory and human selection

```bash
"${GPU_RUNNER}" --action inventory --release 6.4 --output json \
  | tee /root/proxmox-gpu-evidence/inventory.json

jq -e '.adapter.lane == "6.4" and .adapter.default_binding == "early"' \
  /root/proxmox-gpu-evidence/inventory.json
jq '.platform, .adapter, .inventory.gpus[]' \
  /root/proxmox-gpu-evidence/inventory.json
```

A human must select an exact display-function BDF from `display_bdfs`; never
select the first JSON entry automatically.

```bash
read -r -p 'Exact display-function BDF: ' GPU_BDF
read -r -p 'Stopped Q35 VMID: ' VM_ID
read -r -p \
  'Profile (macos-desktop/windows-desktop/linux-desktop/linux-compute): ' \
  GPU_PROFILE

lspci -Dnnk -s "${GPU_BDF}"
qm status "${VM_ID}"
qm config "${VM_ID}" | tee "/root/proxmox-gpu-evidence/qm-${VM_ID}.before.txt"
ha-manager config 2>/dev/null | tee /root/proxmox-gpu-evidence/ha-before.txt
```

Confirm the complete same-slot function set, IOMMU isolation, current drivers,
boot-display state, and absence of assignments to other VMs.

## 4. Preflight and early host preparation

```bash
"${GPU_RUNNER}" \
  --action preflight \
  --release 6.4 \
  --vm "${VM_ID}" \
  --gpu "${GPU_BDF}" \
  --profile "${GPU_PROFILE}" \
  --binding early \
  --output json \
  | tee /root/proxmox-gpu-evidence/preflight.json

"${GPU_RUNNER}" \
  --action prepare \
  --release 6.4 \
  --gpu "${GPU_BDF}" \
  --binding early \
  --dry-run \
  --output json \
  | tee /root/proxmox-gpu-evidence/prepare.dry-run.json
```

Review the dry-run, then prepare without an automatic reboot so the resulting
state and managed files can be inspected:

```bash
"${GPU_RUNNER}" \
  --action prepare \
  --release 6.4 \
  --gpu "${GPU_BDF}" \
  --binding early \
  --yes \
  --output json \
  | tee /root/proxmox-gpu-evidence/prepare.applied.json

jq . /etc/ansible/proxmox/gpu-passthrough/host.state \
  | tee /root/proxmox-gpu-evidence/host.state.pre-reboot.json
```

Require `result.state` to report preparation success, confirm every selected
function and backup in `host.state`, inspect the generated module/initramfs and
boot files, and only then reboot. `--reboot` is supported on `prepare`, but is
deliberately omitted during first commissioning to preserve this checkpoint.

```bash
systemctl reboot
```

## 5. Verify and attach after reboot

Reconnect through the tested management path:

```bash
"${GPU_RUNNER}" --action verify --release 6.4 --output json \
  | tee /root/proxmox-gpu-evidence/verify-host.json

"${GPU_RUNNER}" \
  --test \
  --release 6.4 \
  --vm "${VM_ID}" \
  --gpu "${GPU_BDF}" \
  --profile "${GPU_PROFILE}" \
  --binding early \
  --output json \
  | tee /root/proxmox-gpu-evidence/verify-vm.json
```

Every selected function must use `vfio-pci`. Preview and apply the attachment:

```bash
"${GPU_RUNNER}" \
  --attach \
  --release 6.4 \
  --vm "${VM_ID}" \
  --gpu "${GPU_BDF}" \
  --profile "${GPU_PROFILE}" \
  --binding early \
  --dry-run \
  --output json \
  | tee /root/proxmox-gpu-evidence/attach.dry-run.json

"${GPU_RUNNER}" \
  --attach \
  --release 6.4 \
  --vm "${VM_ID}" \
  --gpu "${GPU_BDF}" \
  --profile "${GPU_PROFILE}" \
  --binding early \
  --yes \
  --output json \
  | tee /root/proxmox-gpu-evidence/attach.applied.json

qm config "${VM_ID}" | tee "/root/proxmox-gpu-evidence/qm-${VM_ID}.attached.txt"
```

For an intentional primary guest display, add all three flags to both attach
commands: `--primary-gpu --allow-guest-console-loss --disable-onboot`. A real
primary attachment also requires `--yes`. Do not use `--start` during initial
commissioning; inspect `qm config` first, then start explicitly.

```bash
qm start "${VM_ID}"
```

Confirm all selected functions and the vendor driver inside the guest. Then run
one controlled second start and collect reset evidence:

```bash
qm shutdown "${VM_ID}" --timeout 60
qm status "${VM_ID}"
qm start "${VM_ID}"
journalctl -b -k | grep -Ei 'vfio|reset|BAR|IOMMU' \
  | tee /root/proxmox-gpu-evidence/kernel-gpu.txt
```

## 6. Optional blacklist fallback

Do not add a blacklist to an existing preparation contract. First detach and
`unprepare` it, reboot to the baseline, and then create a new reviewed
preparation. A vendor blacklist is effective only when the selection includes
every inventoried GPU of that vendor. A partial JSON selection is intentionally
reported under `exact_bind_only_vendors` and does not install a global
blacklist.

This AMD example is dry-run only. Substitute `--blacklist-nvidia` only after
reviewing a complete NVIDIA inventory; use `--blacklist-all` only when every AMD
and NVIDIA GPU may be removed from host drivers.

```bash
"${GPU_RUNNER}" \
  --action prepare \
  --release 6.4 \
  --binding early \
  --blacklist-amd \
  --allow-host-display-loss \
  --yes \
  --dry-run \
  --output json \
  | tee /root/proxmox-gpu-evidence/blacklist.dry-run.json

jq '.gpu_request.requested_features.blacklist //
    .effective_features.blacklist // .result' \
  /root/proxmox-gpu-evidence/blacklist.dry-run.json
```

Require the intended vendor under `effective_vendors`, an empty unexpected
vendor set, the complete affected slot/function list, and no required host
display. Real application uses the same command without `--dry-run`, followed
by inspection of `host.state` and a deliberate reboot. Do not apply it merely
to make a refused dry-run pass.

## 7. Detach, remove a blacklist, and restore the host

Stop the guest. `--remove` detaches only the feature-owned `hostpciN` entry and
restores managed `vga` and `onboot` fields; it never changes host preparation.

```bash
qm shutdown "${VM_ID}" --timeout 60
"${GPU_RUNNER}" --remove --release 6.4 --vm "${VM_ID}" \
  --dry-run --output json \
  | tee /root/proxmox-gpu-evidence/detach.dry-run.json
"${GPU_RUNNER}" --remove --release 6.4 --vm "${VM_ID}" \
  --yes --output json \
  | tee /root/proxmox-gpu-evidence/detach.applied.json

qm config "${VM_ID}" | tee "/root/proxmox-gpu-evidence/qm-${VM_ID}.detached.txt"
```

After every feature-owned VM attachment is gone, copy `host.state` and its
transaction manifest into the evidence directory. Then preview full host
restoration:

```bash
cp -a /etc/ansible/proxmox/gpu-passthrough/host.state \
  /root/proxmox-gpu-evidence/host.state.before-unprepare.json

"${GPU_RUNNER}" --action unprepare --release 6.4 \
  --dry-run --output json \
  | tee /root/proxmox-gpu-evidence/unprepare.dry-run.json
"${GPU_RUNNER}" --action unprepare --release 6.4 \
  --yes --output json \
  | tee /root/proxmox-gpu-evidence/unprepare.applied.json

systemctl reboot
```

`unprepare` removes a feature-installed blacklist by restoring every managed
file to its recorded original content or absence. It does not blindly delete a
blacklist file that existed before the feature. After reboot, compare managed
paths with their pre-test checksums, confirm native driver ownership, confirm
the VM fields match the baseline, and require no feature-owned attachment
state.

If PVE 6 still needs early binding without a blacklist, start a new preparation
from this restored baseline using the section 4 `--gpu ... --binding early`
commands, omit every blacklist selector, inspect state, and reboot again.

## 8. Required evidence and stop conditions

Preserve the feature SHA, workflow URL, `www` deployment commit, all downloaded
checksums, platform/inventory/preflight JSON, dry-run and applied results,
before/after VM configuration, host state, boot files, kernel logs, guest
driver result, stop/start result, and final rollback verification.

Stop for human review on any release mismatch, unexpected GPU or IOMMU member,
boot GPU without an alternate console, running/locked/HA VM, changed Pages SHA,
checksum mismatch, failed transaction rollback, missing backup, bootloader
drift, reset failure, or unexpected loss of a host display.

See [the shared manual](manual.md) for the complete action/state contract and
[the examples](examples.md) for additional schema-v4 blacklist selections.
