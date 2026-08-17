#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${ROOT}/setup/vm/gpu.sh"
COMMON="${ROOT}/cli/gpu/common.sh"
PLATFORM="${ROOT}/cli/gpu/platform.sh"
INVENTORY="${ROOT}/cli/gpu/inventory.sh"
INSPECT="${ROOT}/cli/gpu/inspect.sh"
APPLY="${ROOT}/cli/gpu/apply.sh"
SHARED_PLAYBOOK="${ROOT}/ansible/proxmox/helper/vm.gpu.yml"
MANIFEST="${ROOT}/actions/pages.features.txt"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf '[validate.vm.gpu][error] %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '[validate.vm.gpu][ok] %s\n' "$*"
}

expect_exit() {
  local expected="$1"
  shift
  local observed=0
  "$@" >/dev/null 2>&1 || observed=$?
  [[ "${observed}" -eq "${expected}" ]] || fail "expected exit ${expected}, observed ${observed}: $*"
}

for file in "${RUNNER}" "${PLATFORM}" "${INVENTORY}" "${COMMON}" "${INSPECT}" "${APPLY}"; do
  [[ -f "${file}" ]] || fail "missing GPU shell component: ${file#${ROOT}/}"
  bash -n "${file}" || fail "Bash syntax failed: ${file#${ROOT}/}"
done
ok "public entrypoint and GPU CLI components pass Bash syntax"

for playbook in \
  "${ROOT}/ansible/release/6.4/gpu.yml" \
  "${ROOT}/ansible/release/9.1/gpu.yml" \
  "${SHARED_PLAYBOOK}"; do
  [[ -f "${playbook}" ]] || fail "missing GPU playbook: ${playbook#${ROOT}/}"
done
grep -Fq 'supported_bindings: ["early"]' "${ROOT}/ansible/release/6.4/gpu.yml" || fail "PVE 6.4 release contract does not constrain early binding"
grep -Fq 'supported_bindings: ["automatic", "early"]' "${ROOT}/ansible/release/9.1/gpu.yml" || fail "PVE 9.1 release contract does not expose automatic/early binding"
grep -Fq 'adapter_id: "pve6-buster"' "${ROOT}/ansible/release/6.4/gpu.yml" || fail "PVE 6 adapter identity is missing"
grep -Fq 'adapter_id: "pve9-trixie"' "${ROOT}/ansible/release/9.1/gpu.yml" || fail "PVE 9 adapter identity is missing"

for ref in \
  '"release/6.4/gpu.yml"' \
  '"release/9.1/gpu.yml"' \
  '"proxmox/helper/vm.gpu.yml"' \
  '"gpu/platform.sh"' \
  '"gpu/inventory.sh"' \
  '"gpu/common.sh"' \
  '"gpu/inspect.sh"' \
  '"gpu/apply.sh"'; do
  grep -Fq "${ref}" "${RUNNER}" || fail "runner dependency declaration is missing ${ref}"
done
grep -qx 'setup/vm/gpu.sh|setup/vm/gpu.sh|feature' "${MANIFEST}" || fail "GPU runner is absent from generic Pages manifest"
if rg -n 'SETUP_VM_GPU_RUNNER|feature/vm/gpu.*branches' "${ROOT}/actions/www.pages.sh" "${ROOT}/.github/workflows/www.pages.yml" >/dev/null; then
  fail "GPU publication still uses a feature-specific builder/workflow case"
fi
ok "GPU runner, helpers, and playbooks use the generic publication graph"

for contract in \
  'inventory|preflight|prepare|verify|attach|detach|status|unprepare' \
  '--remove' \
  '--blacklist' \
  '--primary-gpu' \
  '--binding release|automatic|early' \
  '--release 6.4|9.1'; do
  grep -Fq -- "${contract}" "${COMMON}" || grep -Fq -- "${contract}" "${RUNNER}" || fail "public contract marker missing: ${contract}"
done
ok "canonical actions and compatibility flags are declared"

FIXTURE="${TMP_DIR}/fixture"
STUB_BIN="${TMP_DIR}/bin"
SYSFS_ROOT="${FIXTURE}/sys"
PROC_ROOT="${FIXTURE}/proc"
ETC_ROOT="${FIXTURE}/etc"
PVE_ROOT="${FIXTURE}/etc/pve"
STATE_ROOT="${FIXTURE}/state"
VM_CONFIG="${PVE_ROOT}/qemu-server/101.conf"
REQUEST_CAPTURE="${FIXTURE}/request.json"

mkdir -p \
  "${STUB_BIN}" \
  "${PROC_ROOT}" \
  "${ETC_ROOT}/kernel" \
  "${PVE_ROOT}/qemu-server" \
  "${STATE_ROOT}" \
  "${SYSFS_ROOT}/kernel/iommu_groups/12/devices" \
  "${SYSFS_ROOT}/kernel/iommu_groups/13/devices" \
  "${SYSFS_ROOT}/kernel/iommu_groups/14/devices" \
  "${SYSFS_ROOT}/drivers/vfio-pci" \
  "${SYSFS_ROOT}/drivers/amdgpu" \
  "${SYSFS_ROOT}/drivers/nouveau"

make_device() {
  local bdf="$1" class="$2" vendor="$3" device="$4" group="$5" driver="$6" boot="${7:-0}"
  local path="${SYSFS_ROOT}/bus/pci/devices/${bdf}"
  mkdir -p "${path}"
  printf '%s\n' "${class}" > "${path}/class"
  printf '%s\n' "${vendor}" > "${path}/vendor"
  printf '%s\n' "${device}" > "${path}/device"
  printf '%s\n' "${boot}" > "${path}/boot_vga"
  ln -s "../../../../kernel/iommu_groups/${group}" "${path}/iommu_group"
  ln -s "../../../../drivers/${driver}" "${path}/driver"
  ln -s "../../../../bus/pci/devices/${bdf}" "${SYSFS_ROOT}/kernel/iommu_groups/${group}/devices/${bdf}"
}

# Selected AMD GPU uses two independently safe groups. A second identical AMD
# card proves inventory and blacklist-collateral behavior remain address based.
make_device 0000:18:00.0 0x030000 0x1002 0x67e3 12 vfio-pci
make_device 0000:18:00.1 0x040300 0x1002 0xaae0 14 vfio-pci
make_device 0000:3b:00.0 0x030000 0x1002 0x67e3 13 amdgpu

printf '%s\n' \
  'processor: 0' \
  'vendor_id: AuthenticAMD' > "${PROC_ROOT}/cpuinfo"
printf '%s\n' 'BOOT_IMAGE=/boot/vmlinuz iommu=pt' > "${PROC_ROOT}/cmdline"
printf '%s\n' 'root=ZFS=rpool/ROOT/pve-1 boot=zfs' > "${ETC_ROOT}/kernel/cmdline"
printf '%s\n' 'ID=debian' 'VERSION_ID="13"' 'VERSION_CODENAME=trixie' > "${ETC_ROOT}/os-release"
printf '%s\n' \
  'bios: ovmf' \
  'efidisk0: local-lvm:vm-101-disk-0,efitype=4m,size=4M' \
  'hostpci0: 02:00,pcie=1' \
  'machine: q35' \
  'onboot: 1' \
  'vga: std' > "${VM_CONFIG}"

cat > "${STUB_BIN}/qm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  config) cat "${GPU_TEST_VM_CONFIG}" ;;
  status) printf 'status: %s\n' "${GPU_TEST_VM_STATUS:-stopped}" ;;
  set|start) printf 'qm %s\n' "$*" >> "${GPU_TEST_COMMAND_LOG:-/dev/null}" ;;
  *) exit 1 ;;
esac
EOF

cat > "${STUB_BIN}/pveversion" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${GPU_TEST_PVEVERSION:-pve-manager/9.1.0/test}"
EOF

cat > "${STUB_BIN}/ha-manager" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${GPU_TEST_HA_CONFIG:-}"
EOF

cat > "${STUB_BIN}/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
request=""
result=""
for arg in "$@"; do
  case "${arg}" in
    @*) request="${arg#@}" ;;
    gpu_result_path=*) result="${arg#gpu_result_path=}" ;;
  esac
done
[[ -n "${request}" && -n "${result}" ]]
cp "${request}" "${GPU_TEST_REQUEST_CAPTURE}"
jq -c '{schema_version:3,action:.gpu_request.action,platform:.gpu_request.platform,adapter:.gpu_request.adapter,effective_features:.gpu_request.requested_features,result:{state:(if .gpu_request.dry_run == true then "dry-run" else "ok" end),message:"stubbed mutation",rollback_complete:true}}' "${request}" > "${result}"
EOF

for command_name in flock lspci modinfo proxmox-boot-tool reboot update-grub update-initramfs; do
  cat > "${STUB_BIN}/${command_name}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
chmod 0755 "${STUB_BIN}"/*

GPU_ENV=(
  "PATH=${STUB_BIN}:${PATH}"
  "PROXMOX_GPU_TEST_MODE=1"
  "PROXMOX_GPU_SYSFS_ROOT=${SYSFS_ROOT}"
  "PROXMOX_GPU_PROC_ROOT=${PROC_ROOT}"
  "PROXMOX_GPU_ETC_ROOT=${ETC_ROOT}"
  "PROXMOX_GPU_PVE_ROOT=${PVE_ROOT}"
  "PROXMOX_GPU_STATE_ROOT=${STATE_ROOT}"
  "PROXMOX_GPU_BOOTLOADER=proxmox-boot-tool"
  "PROXMOX_GPU_CLI_ROOT=${ROOT}/cli"
  "PROXMOX_GPU_PLAYBOOK_ROOT=${ROOT}/ansible"
  "GPU_TEST_VM_CONFIG=${VM_CONFIG}"
  "GPU_TEST_REQUEST_CAPTURE=${REQUEST_CAPTURE}"
)

inventory_json="$(env "${GPU_ENV[@]}" bash "${RUNNER}" --action inventory --output json)"
jq -e '
  .schema_version == 3
  and .action == "inventory"
  and .platform.pve.version == "9.1.0"
  and .adapter.id == "pve9-trixie"
  and .adapter.playbook == "release/9.1/gpu.yml"
  and (.inventory.gpus | length) == 2
  and ([.inventory.gpus[].functions[]] | length) == 3
  and any(.inventory.gpus[]; .slot == "0000:18:00" and (.functions | length) == 2)
  and all(.inventory.gpus[].functions[]; has("vendor_id") and has("device_id") and has("subsystem_vendor_id") and has("subsystem_device_id"))
' <<< "${inventory_json}" >/dev/null || fail "inventory JSON did not report the complete GPU identity graph"
ok "inventory is machine-readable and captures every GPU slot and function identity"

EMPTY_SYSFS_ROOT="${FIXTURE}/empty-sys"
mkdir -p "${EMPTY_SYSFS_ROOT}/bus/pci/devices"
empty_inventory_json="$(env "${GPU_ENV[@]}" "PROXMOX_GPU_SYSFS_ROOT=${EMPTY_SYSFS_ROOT}" bash "${RUNNER}" --action inventory --output json)"
jq -e '.inventory.gpus == []' <<< "${empty_inventory_json}" >/dev/null || fail "empty GPU inventory did not return an empty list"
expect_exit 4 env "${GPU_ENV[@]}" "PROXMOX_GPU_SYSFS_ROOT=${EMPTY_SYSFS_ROOT}" bash "${RUNNER}" \
  --action preflight --gpu 18:00.0
expect_exit 2 env "${GPU_ENV[@]}" bash "${RUNNER}" --action preflight --gpu 18:00
ok "empty inventory and slot-only GPU input fail without synthesizing a device identity"

status_json="$(env "${GPU_ENV[@]}" bash "${RUNNER}" --action status --output json)"
jq -e '.schema_version == 3 and .action == "status" and (.inventory.gpus | length) == 2 and .facts.prepared == false and .facts.configured_gpu == null and .facts.requested_gpu == null' <<< "${status_json}" >/dev/null || fail "empty status did not preserve inventory and nullable JSON fields"
hardware_preflight_json="$(env "${GPU_ENV[@]}" bash "${RUNNER}" --action preflight --gpu 18:00.0 --output json)"
jq -e '.action == "preflight" and .selection.selected_bdf == "0000:18:00.0" and .facts.vmid == null and .facts.hostpci_index == null and .result.ready == true' <<< "${hardware_preflight_json}" >/dev/null || fail "hardware-only preflight did not preserve explicit selection and nullable JSON fields"
ok "status and hardware-only preflight emit complete JSON without a VM"

preflight_json="$(env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action preflight --vm 101 --gpu 18:00.0 --profile compute --output json)"
jq -e '.result.ready == true and .adapter.lane == "9.1" and .effective_features.binding == "automatic" and (.selection.functions | length) == 2 and .facts.hostpci_index == 1' <<< "${preflight_json}" >/dev/null || fail "PVE 9 preflight contract failed"
ok "PVE 9 selects automatic handoff and accepts safe split IOMMU groups"

expect_exit 4 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action preflight --vm 101 --gpu 18:00.0 --hostpci-index 0
expect_exit 4 env "${GPU_ENV[@]}" "GPU_TEST_VM_STATUS=running" bash "${RUNNER}" \
  --action preflight --vm 101 --gpu 18:00.0
expect_exit 4 env "${GPU_ENV[@]}" "GPU_TEST_HA_CONFIG=vm:101 enabled" bash "${RUNNER}" \
  --action preflight --vm 101 --gpu 18:00.0
ok "occupied hostpci, running VM, and HA ownership fail closed"

expect_exit 4 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --gpu 18:00.0 --blacklist --allow-host-display-loss --yes --dry-run
ok "vendor blacklisting refuses collateral capture of an unselected identical GPU"

env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --attach --vm 101 --gpu 18:00.0 --profile linux-desktop \
  --primary-gpu --allow-guest-console-loss --disable-onboot --yes --dry-run --output json >/dev/null
jq -e '
  .gpu_request.schema_version == 3
  and .gpu_request.action == "attach"
  and .gpu_request.platform.pve.version == "9.1.0"
  and .gpu_request.adapter.id == "pve9-trixie"
  and .gpu_request.adapter.playbook == "release/9.1/gpu.yml"
  and (.gpu_request.inventory.gpus | length) == 2
  and ([.gpu_request.inventory.gpus[].functions[]] | length) == 3
  and .gpu_request.selection.selected_bdf == "0000:18:00.0"
  and .gpu_request.gpu_bdf == "0000:18:00.0"
  and .gpu_request.hostpci_index == 1
  and .gpu_request.requested_features.binding == "automatic"
  and .gpu_request.requested_features.primary_gpu == true
  and .gpu_request.requested_features.disable_onboot == true
  and .gpu_request.detected.iommu_ready == true
  and (.gpu_request.selection.functions | all(.driver == "vfio-pci" and (.iommu_group | length) > 0))
  and (.gpu_request.functions == .gpu_request.selection.functions)
' "${REQUEST_CAPTURE}" >/dev/null || fail "attach request did not preserve platform, inventory, selection, and feature data"
ok "--attach serializes complete inventory and explicit selection for the detected adapter"

expect_exit 3 env "${GPU_ENV[@]}" "PROXMOX_GPU_BOOTLOADER=invalid" bash "${RUNNER}" \
  --attach --vm 101 --gpu 18:00.0 --yes --dry-run
ok "invalid bootloader data is rejected before playbook dispatch"

printf '%s\n' 'ID=debian' 'VERSION_ID="10"' 'VERSION_CODENAME=buster' > "${ETC_ROOT}/os-release"
GPU_TEST_PVEVERSION='pve-manager/6.4.15/test' \
  preflight_pve6="$(env "GPU_TEST_PVEVERSION=pve-manager/6.4.15/test" "${GPU_ENV[@]}" bash "${RUNNER}" \
    --action preflight --release 6.4 --vm 101 --gpu 18:00.0 --output json)"
jq -e '.platform.pve.version == "6.4.15" and .adapter.id == "pve6-buster" and .adapter.lane == "6.4" and .effective_features.binding == "early"' <<< "${preflight_pve6}" >/dev/null || fail "PVE 6/Buster did not resolve the capability adapter and exact-BDF early binding"
expect_exit 3 env "GPU_TEST_PVEVERSION=pve-manager/6.4.15/test" "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action preflight --release 9.1 --vm 101 --gpu 18:00.0
ok "release assertions cannot override detected PVE 6/Buster tooling"

printf '%s\n' 'ID=debian' 'VERSION_ID="13"' 'VERSION_CODENAME=trixie' > "${ETC_ROOT}/os-release"
future_pve9="$(env "GPU_TEST_PVEVERSION=pve-manager/9.9.3/test" "${GPU_ENV[@]}" bash "${RUNNER}" --action inventory --output json)"
jq -e '.platform.pve.version == "9.9.3" and .adapter.id == "pve9-trixie" and .adapter.default_binding == "automatic"' <<< "${future_pve9}" >/dev/null || fail "future compatible PVE 9 minor did not use detected PVE 9/Trixie capabilities"
ok "compatible future PVE 9 minors use the detected family adapter without a minor-version default"

printf '%s\n' 'ID=debian' 'VERSION_ID="11"' 'VERSION_CODENAME=bullseye' > "${ETC_ROOT}/os-release"
expect_exit 3 env "GPU_TEST_PVEVERSION=pve-manager/7.4.0/test" "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action inventory
ok "documented but unimplemented PVE 7/8 lanes fail closed"

printf '%s\n' 'ID=debian' 'VERSION_ID="13"' 'VERSION_CODENAME=trixie' > "${ETC_ROOT}/os-release"
mkdir -p "${SYSFS_ROOT}/bus/pci/devices/0000:5e:00.0" "${SYSFS_ROOT}/kernel/iommu_groups/15/devices"
make_device 0000:5e:00.0 0x030200 0x10de 0x1abc 15 nouveau
expect_exit 4 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action preflight --vm 101 --gpu 5e:00.0 --profile macos
ok "macOS profile rejects NVIDIA hardware before mutation"

mkdir -p "${SYSFS_ROOT}/kernel/iommu_groups/16/devices" "${SYSFS_ROOT}/kernel/iommu_groups/17/devices"
make_device 0000:6a:00.0 0x030000 0x10de 0x2200 16 nouveau
make_device 0000:6a:00.1 0x040300 0x10de 0x1aef 16 nouveau
make_device 0000:6b:00.0 0x020000 0x8086 0x100e 16 vfio-pci
expect_exit 4 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action preflight --vm 101 --gpu 6a:00.0
make_device 0000:7a:00.0 0x030000 0x10de 0x2300 17 nouveau 1
expect_exit 4 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action preflight --vm 101 --gpu 7a:00.0
ok "mixed IOMMU groups and unacknowledged boot displays are refused"

cat > "${STATE_ROOT}/vm-101.state" <<'EOF'
{
  "format": 3,
  "vmid": 101,
  "gpu_bdf": "0000:99:00.2",
  "gpu_slot": "0000:99:00",
  "gpu_functions": ["0000:99:00.2", "0000:99:00.3"],
  "gpu_function_records": [
    {"bdf":"0000:99:00.2","class":"0x030000","vendor_id":"0x1002","device_id":"0x9999","subsystem_vendor_id":null,"subsystem_device_id":null,"driver":"unbound","iommu_group":null,"numa_node":null,"boot_vga":false,"reset_supported":false},
    {"bdf":"0000:99:00.3","class":"0x040300","vendor_id":"0x1002","device_id":"0x9998","subsystem_vendor_id":null,"subsystem_device_id":null,"driver":"unbound","iommu_group":null,"numa_node":null,"boot_vga":false,"reset_supported":false}
  ],
  "hostpci_index": 1,
  "original_vga": "std"
}
EOF
env "${GPU_ENV[@]}" bash "${RUNNER}" --remove --vm 101 --dry-run --output json >/dev/null
jq -e '
  .gpu_request.action == "detach"
  and .gpu_request.gpu_slot == "0000:99:00"
  and .gpu_request.gpu_bdf == "0000:99:00.2"
  and (.gpu_request.selection.functions | map(.bdf)) == ["0000:99:00.2", "0000:99:00.3"]
' "${REQUEST_CAPTURE}" >/dev/null || {
  jq . "${REQUEST_CAPTURE}" >&2
  fail "detach could not recover from state with absent hardware"
}
rm -f "${STATE_ROOT}/vm-101.state"

cat > "${STATE_ROOT}/vm-101.state" <<'EOF'
format=1
vm=101
gpu_slot=0000:97:00
hostpci_index=1
original_vga=std
EOF
expect_exit 4 env "${GPU_ENV[@]}" bash "${RUNNER}" --remove --vm 101 --dry-run
rm -f "${STATE_ROOT}/vm-101.state"

cat > "${STATE_ROOT}/host.state" <<'EOF'
{
  "format": 3,
  "gpu_bdf": "0000:98:00.4",
  "gpu_slot": "0000:98:00",
  "gpu_functions": ["0000:98:00.4", "0000:98:00.5"],
  "gpu_function_records": [
    {"bdf":"0000:98:00.4","class":"0x030200","vendor_id":"0x10de","device_id":"0x9800","subsystem_vendor_id":null,"subsystem_device_id":null,"driver":"unbound","iommu_group":null,"numa_node":null,"boot_vga":false,"reset_supported":false},
    {"bdf":"0000:98:00.5","class":"0x040300","vendor_id":"0x10de","device_id":"0x9801","subsystem_vendor_id":null,"subsystem_device_id":null,"driver":"unbound","iommu_group":null,"numa_node":null,"boot_vga":false,"reset_supported":false}
  ],
  "bootloader": "proxmox-boot-tool",
  "blacklist_host_drivers": false
}
EOF
env "${GPU_ENV[@]}" bash "${RUNNER}" --action unprepare --dry-run --output json >/dev/null
jq -e '
  .gpu_request.action == "unprepare"
  and .gpu_request.gpu_slot == "0000:98:00"
  and .gpu_request.gpu_bdf == "0000:98:00.4"
  and (.gpu_request.functions | map(.bdf)) == ["0000:98:00.4", "0000:98:00.5"]
' "${REQUEST_CAPTURE}" >/dev/null || fail "unprepare could not recover exact functions from schema-v3 state"
rm -f "${STATE_ROOT}/host.state"
ok "absent-hardware recovery requires exact schema-v3 identity and rejects incomplete legacy state"

if rg -n 'amd_iommu=on' "${RUNNER}" "${ROOT}/cli/gpu" "${ROOT}/ansible/release" >/dev/null; then
  fail "runtime components still synthesize the invalid amd_iommu=on parameter"
fi
for marker in \
  'Apply host preparation transaction' \
  'Restore pre-transaction host files' \
  'Apply VM attachment transaction' \
  'Apply VM detachment transaction' \
  'Restore structured original host files'; do
  grep -Fq "${marker}" "${SHARED_PLAYBOOK}" || fail "transaction marker missing: ${marker}"
done
ok "shared playbook contains host/VM transaction and rollback boundaries"

if command -v ansible-playbook >/dev/null 2>&1; then
  ansible-playbook -i localhost, -c local --syntax-check "${ROOT}/ansible/release/6.4/gpu.yml" >/dev/null || fail "PVE 6.4 GPU playbook syntax failed"
  ansible-playbook -i localhost, -c local --syntax-check "${ROOT}/ansible/release/9.1/gpu.yml" >/dev/null || fail "PVE 9.1 GPU playbook syntax failed"
  ok "release GPU playbooks pass Ansible syntax checks"
else
  printf '[validate.vm.gpu][warn] ansible-playbook unavailable; CI will run syntax checks\n' >&2
fi

printf '[validate.vm.gpu] all GPU passthrough contracts passed\n'
