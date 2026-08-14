#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${ROOT}/setup/vm/gpu.sh"
PAGES_BUILDER="${ROOT}/actions/www.pages.sh"
PAGES_VALIDATOR="${ROOT}/actions/validate.pages.sh"
PAGES_WORKFLOW="${ROOT}/.github/workflows/www.pages.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf '[validate.vm.gpu][error] %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '[validate.vm.gpu][ok] %s\n' "$*"
}

[[ -f "${RUNNER}" ]] || fail "missing runner: ${RUNNER}"
bash -n "${RUNNER}" || fail "runner failed bash syntax validation"
ok "runner passes bash syntax validation"

for contract in \
  '--action ACTION' \
  '--blacklist-host-drivers' \
  '--allow-host-display-loss' \
  '--allow-guest-console-loss' \
  '--reboot, --reset' \
  '--test' \
  'detach     Remove only the feature-owned hostpciN' \
  'unprepare  Restore managed host boot/module configuration' \
  'initramfs-tools/scripts/init-top/proxmox-gpu-passthrough' \
  'qm set "${VM_ID}" "-hostpci${selected_index}"'; do
  grep -Fq -- "${contract}" "${RUNNER}" || fail "runner is missing contract marker: ${contract}"
done
ok "runner exposes the initial preparation, test, and attach contract"

grep -Fq 'SETUP_VM_GPU_RUNNER="setup/vm/gpu.sh"' "${PAGES_BUILDER}" || \
  fail "Pages builder does not declare the GPU runner"
grep -Fq 'setup/vm/gpu.sh:setup/vm/gpu.sh' "${PAGES_VALIDATOR}" || \
  fail "Pages validator does not compare the GPU runner"
grep -Fq './actions/validate.vm.gpu.sh' "${PAGES_WORKFLOW}" || \
  fail "Pages workflow does not run the GPU contract validator"
grep -Fq 'branches: [ main, feature/vm/gpu ]' "${PAGES_WORKFLOW}" || \
  fail "feature branch is not enabled for non-deploying Actions validation"
ok "Pages publication and feature-branch validation are wired"

FIXTURE="${TMP_DIR}/fixture"
STUB_BIN="${TMP_DIR}/bin"
SYSFS_ROOT="${FIXTURE}/sys"
PROC_ROOT="${FIXTURE}/proc"
ETC_ROOT="${FIXTURE}/etc"
PVE_ROOT="${FIXTURE}/etc/pve"
STATE_ROOT="${FIXTURE}/state"
COMMAND_LOG="${FIXTURE}/commands.log"
VM_CONFIG="${PVE_ROOT}/qemu-server/101.conf"

mkdir -p \
  "${STUB_BIN}" \
  "${SYSFS_ROOT}/bus/pci/devices/0000:18:00.0" \
  "${SYSFS_ROOT}/bus/pci/devices/0000:18:00.1" \
  "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0" \
  "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.1" \
  "${SYSFS_ROOT}/kernel/iommu_groups/12/devices" \
  "${SYSFS_ROOT}/drivers/vfio-pci" \
  "${PROC_ROOT}" \
  "${ETC_ROOT}/kernel" \
  "${PVE_ROOT}/qemu-server" \
  "${STATE_ROOT}"

printf '0x030000\n' > "${SYSFS_ROOT}/bus/pci/devices/0000:18:00.0/class"
printf '0x040300\n' > "${SYSFS_ROOT}/bus/pci/devices/0000:18:00.1/class"
printf '0\n' > "${SYSFS_ROOT}/bus/pci/devices/0000:18:00.0/boot_vga"
printf '0x030000\n' > "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/class"
printf '0x040300\n' > "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.1/class"
ln -s '../../../../kernel/iommu_groups/12' "${SYSFS_ROOT}/bus/pci/devices/0000:18:00.0/iommu_group"
ln -s '../../../../kernel/iommu_groups/12' "${SYSFS_ROOT}/bus/pci/devices/0000:18:00.1/iommu_group"
ln -s '../../../../drivers/vfio-pci' "${SYSFS_ROOT}/bus/pci/devices/0000:18:00.0/driver"
ln -s '../../../../drivers/vfio-pci' "${SYSFS_ROOT}/bus/pci/devices/0000:18:00.1/driver"
ln -s '../../../../bus/pci/devices/0000:18:00.0' "${SYSFS_ROOT}/kernel/iommu_groups/12/devices/0000:18:00.0"
ln -s '../../../../bus/pci/devices/0000:18:00.1' "${SYSFS_ROOT}/kernel/iommu_groups/12/devices/0000:18:00.1"

printf '%s\n' \
  'processor: 0' \
  'vendor_id: AuthenticAMD' > "${PROC_ROOT}/cpuinfo"
printf '%s\n' 'BOOT_IMAGE=/boot/vmlinuz amd_iommu=on iommu=pt' > "${PROC_ROOT}/cmdline"
printf '%s\n' 'root=ZFS=rpool/ROOT/pve-1 boot=zfs' > "${ETC_ROOT}/kernel/cmdline"
printf '%s\n' \
  'bios: ovmf' \
  'efidisk0: local-lvm:vm-101-disk-0,efitype=4m,size=4M' \
  'hostpci0: 02:00,pcie=1' \
  'machine: q35' \
  'vga: std' > "${VM_CONFIG}"

cat > "${STUB_BIN}/qm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  config) cat "${GPU_TEST_VM_CONFIG}" ;;
  status) printf 'status: stopped\n' ;;
  set|start) printf 'qm %s\n' "$*" >> "${GPU_TEST_COMMAND_LOG}" ;;
  *) exit 1 ;;
esac
EOF

cat > "${STUB_BIN}/pveversion" <<'EOF'
#!/usr/bin/env bash
printf 'pve-manager/9.1.0/test\n'
EOF

cat > "${STUB_BIN}/ha-manager" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${STUB_BIN}/lsmod" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  'Module Size Used by' \
  'vfio_pci 16384 0' \
  'vfio_iommu_type1 40960 0' \
  'vfio 57344 2 vfio_pci,vfio_iommu_type1'
EOF

for command_name in efibootmgr flock lspci proxmox-boot-tool reboot update-grub update-initramfs; do
  cat > "${STUB_BIN}/${command_name}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >> "${GPU_TEST_COMMAND_LOG}"
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
  "PROXMOX_GPU_BOOTLOADER=grub"
  "GPU_TEST_VM_CONFIG=${VM_CONFIG}"
  "GPU_TEST_COMMAND_LOG=${COMMAND_LOG}"
)

env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action preflight --vm 101 --gpu 0000:18:00.0 --profile macos >/dev/null
ok "preflight accepts an isolated complete multifunction GPU and stopped Q35/OVMF VM"

if env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --gpu 0000:18:00.0 --blacklist-host-drivers --dry-run >/dev/null 2>&1; then
  fail "global blacklisting succeeded without the display-loss and confirmation gates"
fi
ok "global host-driver blacklisting requires explicit display-loss confirmation"

env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action prepare --gpu 0000:18:00.0 \
  --blacklist-host-drivers --allow-host-display-loss --yes >/dev/null

grep -qx 'blacklist amdgpu' "${ETC_ROOT}/modprobe.d/proxmox-gpu-passthrough-blacklist.conf" || \
  fail "prepare did not write the reviewed AMD blacklist"
grep -qx 'blacklist nvidia' "${ETC_ROOT}/modprobe.d/proxmox-gpu-passthrough-blacklist.conf" || \
  fail "prepare did not write the reviewed NVIDIA blacklist"
grep -q '0000:18:00.0' "${ETC_ROOT}/initramfs-tools/scripts/init-top/proxmox-gpu-passthrough" || \
  fail "prepare did not reserve the selected VGA function"
grep -q '0000:18:00.1' "${ETC_ROOT}/initramfs-tools/scripts/init-top/proxmox-gpu-passthrough" || \
  fail "prepare did not reserve the selected audio function"
if grep -q '0000:3b:00' "${ETC_ROOT}/initramfs-tools/scripts/init-top/proxmox-gpu-passthrough"; then
  fail "prepare captured an unselected identical GPU"
fi
grep -q 'amd_iommu=on iommu=pt' "${ETC_ROOT}/default/grub.d/proxmox-gpu-passthrough.cfg" || \
  fail "prepare did not configure the CPU-appropriate IOMMU parameters"
grep -q '^update-grub ' "${COMMAND_LOG}" || fail "prepare did not refresh GRUB"
grep -q '^update-initramfs -u -k all$' "${COMMAND_LOG}" || fail "prepare did not refresh initramfs"
ok "prepare writes exact-BDF VFIO state, optional global blacklists, and boot artifacts"

test_json="$(env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --test --vm 101 --gpu 0000:18:00.0 --profile macos --output json)"
printf '%s\n' "${test_json}" | jq -e '.ready == true and .failures == 0 and .gpu == "0000:18:00"' >/dev/null || \
  fail "post-reboot JSON test did not report ready"
ok "--test proves IOMMU, modules, exact VFIO binding, and VM readiness"

env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action attach --vm 101 --gpu 0000:18:00.0 --profile macos \
  --allow-guest-console-loss --yes >/dev/null
grep -q '^qm set 101 -hostpci1 18:00,pcie=1,x-vga=1$' "${COMMAND_LOG}" || \
  fail "attach did not preserve hostpci0 and allocate hostpci1 with the whole slot"
grep -q '^qm set 101 -vga none$' "${COMMAND_LOG}" || \
  fail "desktop attach did not disable the virtual display"
grep -q '^status=attached$' "${STATE_ROOT}/vm-101.state" || \
  fail "attach did not persist completed VM ownership state"
ok "attach preserves existing PCI devices and configures the selected GPU as primary"

printf '%s\n' 'hostpci1: 18:00,pcie=1,x-vga=1' >> "${VM_CONFIG}"
env "${GPU_ENV[@]}" bash "${RUNNER}" --action detach --vm 101 >/dev/null
grep -q '^qm set 101 -delete hostpci1$' "${COMMAND_LOG}" || \
  fail "detach did not remove the feature-owned hostpci entry"
grep -q '^qm set 101 -vga std$' "${COMMAND_LOG}" || \
  fail "detach did not restore the original virtual display"
[[ ! -e "${STATE_ROOT}/vm-101.state" ]] || fail "detach retained stale VM ownership state"
ok "detach removes only the feature-owned PCI entry and restores the prior display"

sed -i.bak '/^hostpci1:/d' "${VM_CONFIG}"
rm -f "${VM_CONFIG}.bak"
env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action unprepare --gpu 0000:18:00.0 --yes >/dev/null
[[ ! -e "${ETC_ROOT}/modprobe.d/proxmox-gpu-passthrough-blacklist.conf" ]] || \
  fail "unprepare retained the feature-owned blacklist"
[[ ! -e "${ETC_ROOT}/initramfs-tools/scripts/init-top/proxmox-gpu-passthrough" ]] || \
  fail "unprepare retained exact-BDF initramfs binding"
[[ ! -e "${STATE_ROOT}/host.state" ]] || fail "unprepare retained stale host ownership state"
ok "unprepare removes feature-owned host configuration and rebuilds boot artifacts"

status_json="$(env "${GPU_ENV[@]}" bash "${RUNNER}" \
  --action status --gpu 0000:18:00.0 --output json)"
printf '%s\n' "${status_json}" | jq -e '.prepared == false and (.functions | length) == 2' >/dev/null || \
  fail "status JSON is invalid or incomplete"
ok "status emits valid machine-readable ownership and function state"

printf '[validate.vm.gpu] all GPU passthrough contracts passed\n'
