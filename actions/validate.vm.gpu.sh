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
EXAMPLES_DOC="${ROOT}/docs/setup/vm/gpu/examples.md"
MANUAL_DOC="${ROOT}/docs/setup/vm/gpu/manual.md"
TMP_DIR="$(mktemp -d)"
ANSIBLE_VENV_ROOT="${TMP_DIR}/ansible-venv"
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
grep -Fq '"ansible.runtime.sh"' "${RUNNER}" || fail "runner dependency declaration is missing ansible.runtime.sh"
grep -qx 'setup/vm/gpu.sh|setup/vm/gpu.sh|feature' "${MANIFEST}" || fail "GPU runner is absent from generic Pages manifest"
if rg -n 'SETUP_VM_GPU_RUNNER|feature/vm/gpu.*branches' "${ROOT}/actions/www.pages.sh" "${ROOT}/.github/workflows/www.pages.yml" >/dev/null; then
  fail "GPU publication still uses a feature-specific builder/workflow case"
fi
ok "GPU runner, helpers, and playbooks use the generic publication graph"

for contract in \
  'inventory|preflight|prepare|verify|attach|detach|status|unprepare' \
  '--remove' \
  '--blacklist' \
  '--blacklist-all' \
  '--blacklist-vendor amd|nvidia' \
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
MULTI_REQUEST_CAPTURE="${FIXTURE}/multi-request.json"
PARTIAL_REQUEST_CAPTURE="${FIXTURE}/partial-request.json"

mkdir -p \
  "${STUB_BIN}" \
  "${ANSIBLE_VENV_ROOT}/bin" \
  "${PROC_ROOT}" \
  "${ETC_ROOT}/kernel" \
  "${PVE_ROOT}/qemu-server" \
  "${STATE_ROOT}" \
  "${SYSFS_ROOT}/kernel/iommu_groups/12/devices" \
  "${SYSFS_ROOT}/kernel/iommu_groups/13/devices" \
  "${SYSFS_ROOT}/kernel/iommu_groups/14/devices" \
  "${SYSFS_ROOT}/kernel/iommu_groups/15/devices" \
  "${SYSFS_ROOT}/kernel/iommu_groups/30/devices" \
  "${SYSFS_ROOT}/drivers/vfio-pci" \
  "${SYSFS_ROOT}/drivers/amdgpu" \
  "${SYSFS_ROOT}/drivers/mgag200" \
  "${SYSFS_ROOT}/drivers/nouveau" \
  "${SYSFS_ROOT}/drivers/snd_hda_intel"

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
make_device 0000:03:00.0 0x030000 0x102b 0x0536 30 mgag200 1
make_device 0000:18:00.0 0x030000 0x1002 0x67e3 12 vfio-pci
make_device 0000:18:00.1 0x040300 0x1002 0xaae0 14 vfio-pci
make_device 0000:3b:00.0 0x030000 0x1002 0x67e3 13 amdgpu
make_device 0000:3b:00.1 0x040300 0x1002 0xaae0 13 snd_hda_intel
make_device 0000:5e:00.0 0x030200 0x10de 0x1abc 15 nouveau

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
if [[ "${1:-}" == --version ]]; then
  printf 'ansible-playbook [core 2.20.5]\n'
  exit 0
fi
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
jq -c '{schema_version:4,action:.gpu_request.action,platform:.gpu_request.platform,adapter:.gpu_request.adapter,effective_features:.gpu_request.requested_features,result:{state:(if .gpu_request.dry_run == true then "dry-run" else "ok" end),message:"stubbed mutation",rollback_complete:true}}' "${request}" > "${result}"
EOF

for command_name in flock lspci modinfo proxmox-boot-tool reboot update-grub update-initramfs; do
  cat > "${STUB_BIN}/${command_name}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
chmod 0755 "${STUB_BIN}"/*
cp "${STUB_BIN}/ansible-playbook" "${ANSIBLE_VENV_ROOT}/bin/ansible-playbook"
ln -s "$(command -v python3)" "${ANSIBLE_VENV_ROOT}/bin/python"

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
  "PROXMOX_ANSIBLE_RUNTIME_HELPER=${ROOT}/bootstrap/ansible.runtime.sh"
  "PROXMOX_ANSIBLE_VENV=${ANSIBLE_VENV_ROOT}"
  "GPU_TEST_VM_CONFIG=${VM_CONFIG}"
  "GPU_TEST_REQUEST_CAPTURE=${REQUEST_CAPTURE}"
)

inventory_json="$(env "${GPU_ENV[@]}" bash "${RUNNER}" --action inventory --output json)"
jq -e '
  .schema_version == 4
  and .action == "inventory"
  and .platform.pve.version == "9.1.0"
  and .adapter.id == "pve9-trixie"
  and .adapter.playbook == "release/9.1/gpu.yml"
  and (.inventory.gpus | length) == 4
  and ([.inventory.gpus[].functions[]] | length) == 6
  and any(.inventory.gpus[]; .slot == "0000:18:00" and (.functions | length) == 2)
  and any(.inventory.gpus[]; .slot == "0000:03:00" and .boot_vga == true)
  and all(.inventory.gpus[].functions[]; has("vendor_id") and has("device_id") and has("subsystem_vendor_id") and has("subsystem_device_id"))
' <<< "${inventory_json}" >/dev/null || fail "inventory JSON did not report the complete GPU identity graph"
ok "inventory is machine-readable and captures every GPU slot and function identity"

mv "${ETC_ROOT}/kernel/cmdline" "${ETC_ROOT}/kernel/cmdline.proxmox-boot-tool"
mkdir -p "${ETC_ROOT}/default/grub.d"
grub_inventory_json="$(env "${GPU_ENV[@]}" \
  "PATH=${STUB_BIN}:/usr/bin:/bin" \
  "PROXMOX_GPU_BOOTLOADER=" \
  "GPU_TEST_PVEVERSION=pve-manager/9.2.10/test" \
  bash "${RUNNER}" --action inventory --output json)"
jq -e '
  .platform.pve.version == "9.2.10"
  and .platform.debian.codename == "trixie"
  and .platform.bootloader == "grub"
  and .adapter.id == "pve9-trixie"
' <<< "${grub_inventory_json}" >/dev/null || fail "PVE 9/Trixie GRUB inventory did not validate update-grub capabilities"
mv "${ETC_ROOT}/kernel/cmdline.proxmox-boot-tool" "${ETC_ROOT}/kernel/cmdline"
ok "PVE 9/Trixie GRUB inventory requires update-grub, not a grub executable"

EMPTY_SYSFS_ROOT="${FIXTURE}/empty-sys"
mkdir -p "${EMPTY_SYSFS_ROOT}/bus/pci/devices"
empty_inventory_json="$(env "${GPU_ENV[@]}" "PROXMOX_GPU_SYSFS_ROOT=${EMPTY_SYSFS_ROOT}" bash "${RUNNER}" --action inventory --output json)"
jq -e '.inventory.gpus == []' <<< "${empty_inventory_json}" >/dev/null || fail "empty GPU inventory did not return an empty list"
expect_exit 4 env "${GPU_ENV[@]}" "PROXMOX_GPU_SYSFS_ROOT=${EMPTY_SYSFS_ROOT}" bash "${RUNNER}" \
  --action preflight --gpu 18:00.0
expect_exit 2 env "${GPU_ENV[@]}" bash "${RUNNER}" --action preflight --gpu 18:00
ok "empty inventory and slot-only GPU input fail without synthesizing a device identity"

status_json="$(env "${GPU_ENV[@]}" bash "${RUNNER}" --action status --output json)"
jq -e '.schema_version == 4 and .action == "status" and (.inventory.gpus | length) == 4 and .facts.prepared == false and .facts.configured_gpu == null and .facts.configured_gpus == [] and .facts.requested_gpu == null' <<< "${status_json}" >/dev/null || fail "empty status did not preserve inventory and nullable JSON fields"
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
  --action prepare --gpu 18:00.0 --binding early --blacklist --allow-host-display-loss --yes --dry-run
ok "vendor blacklisting refuses collateral capture of an unselected identical GPU"

env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist-amd --allow-host-display-loss --yes --dry-run --output json >/dev/null
jq -e '
  .gpu_request.schema_version == 4
  and .gpu_request.selection == null
  and .gpu_request.selection_set.mode == "host-set"
  and (.gpu_request.selection_set.gpus | length) == 2
  and (.gpu_request.selection_set.functions | length) == 4
  and (.gpu_request.requested_features.blacklist.affected_function_bdfs | length) == 4
  and .gpu_request.requested_features.blacklist.effective_vendors == ["amd"]
  and .gpu_request.requested_features.blacklist.exact_bind_only_vendors == []
' "${REQUEST_CAPTURE}" >/dev/null || fail "AMD all-selection did not serialize the complete host set"

env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist-nvidia \
  --allow-host-display-loss --yes --dry-run --output json >/dev/null
jq -e '
  .gpu_request.selection_set.mode == "single"
  and .gpu_request.selection_set.slots == ["0000:5e:00"]
  and .gpu_request.requested_features.blacklist.effective_vendors == ["nvidia"]
' "${REQUEST_CAPTURE}" >/dev/null || fail "NVIDIA all-selection did not serialize the inventoried vendor set"

env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist-all \
  --allow-host-display-loss --yes --dry-run --output json >/dev/null
jq -e '
  (.gpu_request.selection_set.gpus | length) == 3
  and (.gpu_request.selection_set.functions | length) == 5
  and (.gpu_request.requested_features.blacklist.affected_function_bdfs | length) == 5
  and (.gpu_request.selection_set.slots | index("0000:03:00")) == null
  and .gpu_request.requested_features.blacklist.effective_vendors == ["amd", "nvidia"]
' "${REQUEST_CAPTURE}" >/dev/null || fail "all-vendor selection included an unsupported boot display or omitted a supported GPU"
cp "${REQUEST_CAPTURE}" "${MULTI_REQUEST_CAPTURE}"

env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist-vendor amd \
  --blacklist-gpu 18:00.0 --blacklist-gpu 0000:3b:00.0 \
  --allow-host-display-loss --yes --dry-run --output json >/dev/null
jq -e '
  (.gpu_request.selection_set.gpus | length) == 2
  and .gpu_request.requested_features.blacklist.effective_vendors == ["amd"]
' "${REQUEST_CAPTURE}" >/dev/null || fail "repeatable AMD BDF selection did not recognize complete vendor coverage"

env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist '{"amd":["18:00.0"]}' \
  --allow-host-display-loss --yes --dry-run --output json >/dev/null
jq -e '
  .gpu_request.schema_version == 4
  and .gpu_request.selection_set.mode == "single"
  and .gpu_request.requested_features.blacklist.effective_vendors == []
  and .gpu_request.requested_features.blacklist.exact_bind_only_vendors == ["amd"]
  and .gpu_request.requested_features.blacklist_host_drivers == false
' "${REQUEST_CAPTURE}" >/dev/null || fail "partial AMD JSON did not downgrade to exact-BDF early binding"
cp "${REQUEST_CAPTURE}" "${PARTIAL_REQUEST_CAPTURE}"

env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist '{"AMD":["18:00.0"],"NVIDIA":"ALL"}' \
  --allow-host-display-loss --yes --dry-run --output json >/dev/null
jq -e '
  (.gpu_request.selection_set.gpus | length) == 2
  and .gpu_request.requested_features.blacklist.requested_vendors == ["amd", "nvidia"]
  and .gpu_request.requested_features.blacklist.effective_vendors == ["nvidia"]
  and .gpu_request.requested_features.blacklist.exact_bind_only_vendors == ["amd"]
' "${REQUEST_CAPTURE}" >/dev/null || fail "mixed case-insensitive JSON did not preserve global and exact-bind-only vendor policy"

expect_exit 2 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist '{"AMD":"all","amd":"all"}' --allow-host-display-loss --yes --dry-run
expect_exit 2 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist '{"amd":[]}' --allow-host-display-loss --yes --dry-run
expect_exit 2 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist '{"amd":["18:00.0",7]}' --allow-host-display-loss --yes --dry-run
expect_exit 2 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist '{"intel":"all"}' --allow-host-display-loss --yes --dry-run
expect_exit 2 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist '{"amd":["18:00"]}' --allow-host-display-loss --yes --dry-run
expect_exit 2 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist-amd --blacklist-nvidia --allow-host-display-loss --yes --dry-run
expect_exit 2 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --gpu 18:00.0 --binding early --blacklist-amd --allow-host-display-loss --yes --dry-run
expect_exit 4 env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --binding early --blacklist '{"amd":["0000:5e:00.0"]}' --allow-host-display-loss --yes --dry-run
ok "multi-GPU, mixed-vendor, and partial exact-binding requests serialize explicit schema-v4 policy"

env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --attach --vm 101 --gpu 18:00.0 --profile linux-desktop \
  --primary-gpu --allow-guest-console-loss --disable-onboot --yes --dry-run --output json >/dev/null
jq -e '
  .gpu_request.schema_version == 4
  and .gpu_request.action == "attach"
  and .gpu_request.platform.pve.version == "9.1.0"
  and .gpu_request.adapter.id == "pve9-trixie"
  and .gpu_request.adapter.playbook == "release/9.1/gpu.yml"
  and (.gpu_request.inventory.gpus | length) == 4
  and ([.gpu_request.inventory.gpus[].functions[]] | length) == 6
  and .gpu_request.selection.selected_bdf == "0000:18:00.0"
  and .gpu_request.selection_set.mode == "single"
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

if command -v ansible-playbook >/dev/null 2>&1; then
  REAL_ANSIBLE_PLAYBOOK="$(command -v ansible-playbook)"
  REAL_MULTI_GPU_RESULT="${FIXTURE}/real-multi-ansible-result.json"
  REAL_PARTIAL_GPU_RESULT="${FIXTURE}/real-partial-ansible-result.json"
  REAL_GPU_RESULT="${FIXTURE}/real-ansible-result.json"
  env "PATH=${STUB_BIN}:${PATH}" "${REAL_ANSIBLE_PLAYBOOK}" \
    -i localhost, -c local \
    -e "ansible_python_interpreter=$(command -v python3)" \
    -e "@${MULTI_REQUEST_CAPTURE}" \
    -e "gpu_result_path=${REAL_MULTI_GPU_RESULT}" \
    "${ROOT}/ansible/release/9.1/gpu.yml" >/dev/null
  jq -e '
    .schema_version == 4
    and .action == "prepare"
    and (.request.gpu_slots | length) == 3
    and .result.state == "dry-run"
  ' "${REAL_MULTI_GPU_RESULT}" >/dev/null || fail "real Ansible multi-GPU preparation dry-run did not complete"
  env "PATH=${STUB_BIN}:${PATH}" "${REAL_ANSIBLE_PLAYBOOK}" \
    -i localhost, -c local \
    -e "ansible_python_interpreter=$(command -v python3)" \
    -e "@${PARTIAL_REQUEST_CAPTURE}" \
    -e "gpu_result_path=${REAL_PARTIAL_GPU_RESULT}" \
    "${ROOT}/ansible/release/9.1/gpu.yml" >/dev/null
  jq -e '
    .schema_version == 4
    and .action == "prepare"
    and .effective_features.blacklist_host_drivers == false
    and (.effective_features.blacklist.exact_bind_only_vendors == ["amd"])
    and (.warnings | length) == 1
    and .result.state == "dry-run"
  ' "${REAL_PARTIAL_GPU_RESULT}" >/dev/null || fail "real Ansible partial exact-binding dry-run did not report its warning"
  env "PATH=${STUB_BIN}:${PATH}" "${REAL_ANSIBLE_PLAYBOOK}" \
    -i localhost, -c local \
    -e "ansible_python_interpreter=$(command -v python3)" \
    -e "@${REQUEST_CAPTURE}" \
    -e "gpu_result_path=${REAL_GPU_RESULT}" \
    "${ROOT}/ansible/release/9.1/gpu.yml" >/dev/null
  jq -e '.schema_version == 4 and .action == "attach" and .result.state == "dry-run"' \
    "${REAL_GPU_RESULT}" >/dev/null || fail "real Ansible attachment dry-run did not complete"
  ok "Ansible 2.20 executes multi-GPU preparation and stopped-VM attachment without broken-condition compatibility"
fi

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

cat > "${STATE_ROOT}/host.state" <<'EOF'
{
  "format": 4,
  "gpu_bdf": null,
  "gpu_slot": null,
  "gpu_bdfs": ["0000:18:00.0", "0000:3b:00.0"],
  "gpu_slots": ["0000:18:00", "0000:3b:00"],
  "gpu_selections": [
    {
      "slot":"0000:18:00",
      "selected_bdf":"0000:18:00.0",
      "display_bdfs":["0000:18:00.0"],
      "functions":[
        {"bdf":"0000:18:00.0","class":"0x030000","vendor_id":"0x1002","device_id":"0x67e3","subsystem_vendor_id":null,"subsystem_device_id":null,"driver":"vfio-pci","iommu_group":"12","numa_node":null,"boot_vga":false,"reset_supported":false},
        {"bdf":"0000:18:00.1","class":"0x040300","vendor_id":"0x1002","device_id":"0xaae0","subsystem_vendor_id":null,"subsystem_device_id":null,"driver":"vfio-pci","iommu_group":"14","numa_node":null,"boot_vga":false,"reset_supported":false}
      ],
      "boot_vga":false,
      "reset_supported":false,
      "vm_assignments":[]
    },
    {
      "slot":"0000:3b:00",
      "selected_bdf":"0000:3b:00.0",
      "display_bdfs":["0000:3b:00.0"],
      "functions":[
        {"bdf":"0000:3b:00.0","class":"0x030000","vendor_id":"0x1002","device_id":"0x67e3","subsystem_vendor_id":null,"subsystem_device_id":null,"driver":"vfio-pci","iommu_group":"13","numa_node":null,"boot_vga":false,"reset_supported":false},
        {"bdf":"0000:3b:00.1","class":"0x040300","vendor_id":"0x1002","device_id":"0xaae0","subsystem_vendor_id":null,"subsystem_device_id":null,"driver":"vfio-pci","iommu_group":"13","numa_node":null,"boot_vga":false,"reset_supported":false}
      ],
      "boot_vga":false,
      "reset_supported":false,
      "vm_assignments":[]
    }
  ],
  "gpu_functions": ["0000:18:00.0", "0000:18:00.1", "0000:3b:00.0", "0000:3b:00.1"],
  "gpu_function_records": [
    {"bdf":"0000:18:00.0","class":"0x030000","vendor_id":"0x1002","device_id":"0x67e3","subsystem_vendor_id":null,"subsystem_device_id":null,"driver":"vfio-pci","iommu_group":"12","numa_node":null,"boot_vga":false,"reset_supported":false},
    {"bdf":"0000:18:00.1","class":"0x040300","vendor_id":"0x1002","device_id":"0xaae0","subsystem_vendor_id":null,"subsystem_device_id":null,"driver":"vfio-pci","iommu_group":"14","numa_node":null,"boot_vga":false,"reset_supported":false},
    {"bdf":"0000:3b:00.0","class":"0x030000","vendor_id":"0x1002","device_id":"0x67e3","subsystem_vendor_id":null,"subsystem_device_id":null,"driver":"vfio-pci","iommu_group":"13","numa_node":null,"boot_vga":false,"reset_supported":false},
    {"bdf":"0000:3b:00.1","class":"0x040300","vendor_id":"0x1002","device_id":"0xaae0","subsystem_vendor_id":null,"subsystem_device_id":null,"driver":"vfio-pci","iommu_group":"13","numa_node":null,"boot_vga":false,"reset_supported":false}
  ],
  "release":"9.1",
  "binding_strategy":"early",
  "blacklist_vendors":["amd"],
  "exact_bind_only_vendors":[],
  "bootloader":"proxmox-boot-tool",
  "transaction_dir":"/tmp/fixture-transaction",
  "original_files":[],
  "applied_files":[]
}
EOF
ln -sfn "../../../../drivers/vfio-pci" "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/driver"
ln -sfn "../../../../drivers/vfio-pci" "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.1/driver"

format4_verify_json="$(env "${GPU_ENV[@]}" bash "${RUNNER}" --action verify --output json)"
jq -e '
  .schema_version == 4
  and .selection == null
  and .selection_set.mode == "host-set"
  and (.selection_set.gpus | length) == 2
  and (.selection_set.functions | length) == 4
  and .result.ready == true
' <<< "${format4_verify_json}" >/dev/null || fail "host-wide verify did not recover the complete schema-v4 selection"

env "${GPU_ENV[@]}" bash "${RUNNER}" --action unprepare --dry-run --output json >/dev/null
jq -e '
  .gpu_request.action == "unprepare"
  and .gpu_request.gpu_slot == null
  and .gpu_request.gpu_bdf == null
  and .gpu_request.selection == null
  and .gpu_request.selection_set.mode == "host-set"
  and (.gpu_request.selection_set.slots | length) == 2
  and (.gpu_request.functions | length) == 4
  and .gpu_request.requested_features.blacklist.effective_vendors == ["amd"]
' "${REQUEST_CAPTURE}" >/dev/null || fail "unprepare did not recover complete schema-v4 multi-GPU ownership"
rm -f "${STATE_ROOT}/host.state"
ok "schema-v3 single-GPU and schema-v4 multi-GPU state remain recoverable without invented identities"

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

for marker in \
  'Manual PVE 9 primary-GPU replacement acceptance scenario' \
  'qm set "${VM_ID}" --delete hostpci0' \
  'current primary-GPU confirmation gate accepts either' \
  'Exercise the vendor-blacklist refusal' \
  'do not stream a mutating action'; do
  grep -Fq "${marker}" "${EXAMPLES_DOC}" || fail "manual acceptance documentation is missing: ${marker}"
done
grep -Fq 'examples.md#manual-pve-9-primary-gpu-replacement-acceptance-scenario' "${MANUAL_DOC}" \
  || fail "GPU manual does not link the primary-GPU replacement acceptance scenario"
grep -Fq 'docs/setup/vm/gpu/examples.md' "${ROOT}/readme.md" \
  || fail "repository documentation index does not link GPU acceptance examples"
ok "manual primary-GPU replacement acceptance documentation is indexed and complete"

if command -v ansible-playbook >/dev/null 2>&1; then
  ansible-playbook -i localhost, -c local --syntax-check "${ROOT}/ansible/release/6.4/gpu.yml" >/dev/null || fail "PVE 6.4 GPU playbook syntax failed"
  ansible-playbook -i localhost, -c local --syntax-check "${ROOT}/ansible/release/9.1/gpu.yml" >/dev/null || fail "PVE 9.1 GPU playbook syntax failed"
  ok "release GPU playbooks pass Ansible syntax checks"
else
  printf '[validate.vm.gpu][warn] ansible-playbook unavailable; CI will run syntax checks\n' >&2
fi

printf '[validate.vm.gpu] all GPU passthrough contracts passed\n'
