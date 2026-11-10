#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${ROOT}/setup/gpu.amd.sh"
MANIFEST="${ROOT}/actions/pages.features.txt"
TMP_ROOT="$(mktemp -d)"
FIXTURE="${TMP_ROOT}/root"
STUB_BIN="${TMP_ROOT}/bin"
COMMAND_LOG="${TMP_ROOT}/commands.log"
MODULE_READY="${TMP_ROOT}/module.ready"
PVE_FIRMWARE_READY="${TMP_ROOT}/pve-firmware.ready"
JOURNAL_FILE="${TMP_ROOT}/journal.log"
INITRAMFS_FAILURE_USED="${TMP_ROOT}/initramfs.failure.used"
GPU_PATH="${FIXTURE}/sys/bus/pci/devices/0000:18:00.0"
PASSTHROUGH_ROOT="${FIXTURE}/etc/ansible/proxmox/gpu-passthrough"
PASSTHROUGH_STATE="${PASSTHROUGH_ROOT}/host.state"
PASSTHROUGH_TX="${PASSTHROUGH_ROOT}/transactions/fixture"
PT_MODULES="${FIXTURE}/etc/modules-load.d/proxmox-gpu-passthrough.conf"
PT_BLACKLIST="${FIXTURE}/etc/modprobe.d/proxmox-gpu-passthrough-blacklist.conf"
PT_GRUB="${FIXTURE}/etc/default/grub.d/proxmox-gpu-passthrough.cfg"
PT_CMDLINE="${FIXTURE}/etc/kernel/cmdline"
PT_HOOK="${FIXTURE}/etc/initramfs-tools/hooks/proxmox-gpu-passthrough"
PT_SCRIPT="${FIXTURE}/etc/initramfs-tools/scripts/init-top/proxmox-gpu-passthrough"
trap 'rm -rf "${TMP_ROOT}"' EXIT

fail() {
  printf '[validate.gpu.amd][error] %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '[validate.gpu.amd][ok] %s\n' "$*"
}

expect_exit() {
  local expected="$1"
  shift
  local observed=0
  "$@" >/dev/null 2>&1 || observed=$?
  [[ "${observed}" == "${expected}" ]] \
    || fail "expected exit ${expected}, observed ${observed}: $*"
}

write_passthrough_state() {
  rm -rf "${PASSTHROUGH_ROOT}"
  mkdir -p \
    "${PASSTHROUGH_TX}" \
    "$(dirname "${PT_MODULES}")" \
    "$(dirname "${PT_BLACKLIST}")" \
    "$(dirname "${PT_GRUB}")" \
    "$(dirname "${PT_CMDLINE}")" \
    "$(dirname "${PT_HOOK}")" \
    "$(dirname "${PT_SCRIPT}")"
  printf '%s\n' '# Managed by setup/vm/gpu.sh (schema 2)' 'vfio' 'vfio_pci' > "${PT_MODULES}"
  printf '%s\n' '# Managed by setup/vm/gpu.sh (schema 2)' 'blacklist amdgpu' 'blacklist radeon' > "${PT_BLACKLIST}"
  printf '%s\n' '# Managed by setup/vm/gpu.sh (schema 2)' 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT amd_iommu=on"' > "${PT_GRUB}"
  printf '%s\n' 'quiet amd_iommu=on' > "${PT_CMDLINE}"
  printf '%s\n' '#!/bin/sh' '# Managed by setup/vm/gpu.sh (schema 2)' > "${PT_HOOK}"
  printf '%s\n' '#!/bin/sh' '# Managed by setup/vm/gpu.sh (schema 2)' 'echo vfio-pci > /sys/bus/pci/devices/0000:18:00.0/driver_override' > "${PT_SCRIPT}"
  chmod 0755 "${PT_HOOK}" "${PT_SCRIPT}"
  printf '%s\n' 'quiet' > "${PASSTHROUGH_TX}/kernel_cmdline"

  cat > "${PASSTHROUGH_STATE}" <<EOF
{
  "format": 4,
  "gpu_bdf": "0000:18:00.0",
  "gpu_slot": "0000:18:00",
  "gpu_bdfs": ["0000:18:00.0"],
  "gpu_slots": ["0000:18:00"],
  "gpu_functions": ["0000:18:00.0"],
  "gpu_function_records": [{"bdf":"0000:18:00.0","vendor_id":"0x1002"}],
  "release": "9.1",
  "binding_strategy": "early",
  "blacklist_vendor": "amd",
  "blacklist_vendors": ["amd"],
  "bootloader": "grub",
  "transaction_dir": "${PASSTHROUGH_TX}",
  "original_files": [
    {"key":"modules","path":"${PT_MODULES}","existed":false,"checksum":"","backup":"${PASSTHROUGH_TX}/modules"},
    {"key":"blacklist","path":"${PT_BLACKLIST}","existed":false,"checksum":"","backup":"${PASSTHROUGH_TX}/blacklist"},
    {"key":"grub_dropin","path":"${PT_GRUB}","existed":false,"checksum":"","backup":"${PASSTHROUGH_TX}/grub_dropin"},
    {"key":"kernel_cmdline","path":"${PT_CMDLINE}","existed":true,"checksum":"deadbeef","backup":"${PASSTHROUGH_TX}/kernel_cmdline"},
    {"key":"initramfs_hook","path":"${PT_HOOK}","existed":false,"checksum":"","backup":"${PASSTHROUGH_TX}/initramfs_hook"},
    {"key":"initramfs_script","path":"${PT_SCRIPT}","existed":false,"checksum":"","backup":"${PASSTHROUGH_TX}/initramfs_script"}
  ],
  "applied_files": [
    {"key":"modules","path":"${PT_MODULES}","existed":true,"checksum":"deadbeef"},
    {"key":"blacklist","path":"${PT_BLACKLIST}","existed":true,"checksum":"deadbeef"},
    {"key":"grub_dropin","path":"${PT_GRUB}","existed":true,"checksum":"deadbeef"},
    {"key":"kernel_cmdline","path":"${PT_CMDLINE}","existed":true,"checksum":"deadbeef"},
    {"key":"initramfs_hook","path":"${PT_HOOK}","existed":true,"checksum":"deadbeef"},
    {"key":"initramfs_script","path":"${PT_SCRIPT}","existed":true,"checksum":"deadbeef"}
  ]
}
EOF
}

[[ -f "${RUNNER}" ]] || fail "missing setup/gpu.amd.sh"
bash -n "${RUNNER}" || fail "runner failed Bash syntax"
grep -qx 'setup/gpu.amd.sh|setup.gpu.amd.sh|plain' "${MANIFEST}" \
  || fail "runner is absent from the Pages manifest"
grep -Fq 'setup.gpu.amd.sh' "${ROOT}/readme.md" \
  || fail "root README does not document the runner"
grep -Fq 'setup.gpu.amd.sh' "${ROOT}/docs/readme.md" \
  || fail "entrypoint guide does not document the runner"
grep -Fq 'wget -qO- https://devs-guide.github.io/proxmox/setup.gpu.amd.sh | sudo bash' "${ROOT}/readme.md" \
  || fail "root README does not document streamed AMDGPU setup"
grep -Fq 'sudo bash -s -- --blacklist --yes' "${ROOT}/docs/readme.md" \
  || fail "entrypoint guide does not document streamed AMDGPU blacklist"
grep -Fq 'sudo bash -s -- --dry-run' "${ROOT}/docs/readme.md" \
  || fail "entrypoint guide does not document streamed AMDGPU takeover preview"
if grep -Fq 'wget -O ./setup.gpu.amd.sh' "${ROOT}/readme.md" "${ROOT}/docs/readme.md"; then
  fail "AMDGPU documentation must not require a downloaded runner"
fi
ok "runner syntax, publication, and endpoint-only documentation contracts are present"

mkdir -p \
  "${STUB_BIN}" \
  "${GPU_PATH}/hwmon/hwmon0" \
  "${FIXTURE}/sys/drivers/amdgpu" \
  "${FIXTURE}/sys/drivers/vfio-pci" \
  "${FIXTURE}/boot" \
  "${FIXTURE}/etc/modprobe.d" \
  "${FIXTURE}/etc/modules-load.d" \
  "${FIXTURE}/etc/default/grub.d" \
  "${FIXTURE}/etc/kernel" \
  "${FIXTURE}/etc/initramfs-tools/hooks" \
  "${FIXTURE}/etc/initramfs-tools/scripts/init-top" \
  "${FIXTURE}/etc/pve/qemu-server" \
  "${FIXTURE}/usr/lib/modprobe.d" \
  "${FIXTURE}/proc" \
  "${FIXTURE}/lib/firmware/amdgpu"

printf '%s\n' 'VERSION_CODENAME=trixie' > "${FIXTURE}/etc/os-release"
printf '%s\n' 'quiet' > "${FIXTURE}/proc/cmdline"
printf '%s\n' '0x1002' > "${GPU_PATH}/vendor"
printf '%s\n' '0x030000' > "${GPU_PATH}/class"
printf '%s\n' '1' > "${GPU_PATH}/boot_vga"
printf '%s\n' 'amdgpu' > "${GPU_PATH}/hwmon/hwmon0/name"
printf '%s\n' 'edge' > "${GPU_PATH}/hwmon/hwmon0/temp1_label"
printf '%s\n' '55000' > "${GPU_PATH}/hwmon/hwmon0/temp1_input"
touch "${FIXTURE}/boot/vmlinuz-6.14.11-4-pve" "${MODULE_READY}" "${PVE_FIRMWARE_READY}"
ln -s "${FIXTURE}/sys/drivers/amdgpu" "${GPU_PATH}/driver"
: > "${COMMAND_LOG}"
: > "${JOURNAL_FILE}"

cat > "${STUB_BIN}/pveversion" <<'EOF'
#!/usr/bin/env bash
printf 'pve-manager/%s/test\n' "${AMDGPU_TEST_PVE_VERSION:-9.2.10}"
EOF

cat > "${STUB_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -r ]] || exit 2
printf '%s\n' '6.14.11-4-pve'
EOF

cat > "${STUB_BIN}/modinfo" <<'EOF'
#!/usr/bin/env bash
[[ -e "${AMDGPU_TEST_MODULE_READY}" ]]
EOF

cat > "${STUB_BIN}/dpkg-query" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -S)
    printf 'proxmox-kernel-6.14.11-4-pve-signed: %s\n' "${2:-}"
    ;;
  -W)
    [[ -e "${AMDGPU_TEST_PVE_FIRMWARE_READY}" ]] || exit 1
    printf 'ii '
    ;;
  *) exit 2 ;;
esac
EOF

cat > "${STUB_BIN}/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'apt-get %s\n' "$*" >> "${AMDGPU_TEST_COMMAND_LOG}"
case " $* " in
  *' -s install '*)
    if [[ "${AMDGPU_TEST_APT_CONFLICT:-0}" == 1 ]]; then
      printf '%s\n' 'Remv proxmox-ve [9.0.0]'
    else
      printf '%s\n' 'Inst pve-firmware'
    fi
    ;;
  *' download firmware-amd-graphics '*)
    touch firmware-amd-graphics_1_all.deb
    ;;
  *' install '*)
    touch "${AMDGPU_TEST_MODULE_READY}" "${AMDGPU_TEST_PVE_FIRMWARE_READY}"
    ;;
  *) exit 2 ;;
esac
EOF

cat > "${STUB_BIN}/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -f) printf '%s\n' 'firmware-amd-graphics' ;;
  -x)
    mkdir -p "${3}/lib/firmware/amdgpu"
    printf '%s\n' 'fixture firmware' > "${3}/lib/firmware/amdgpu/test.bin"
    ;;
  *) exit 2 ;;
esac
EOF

cat > "${STUB_BIN}/modprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -e "${AMDGPU_TEST_MODULE_READY}" ]] || exit 1
driver="${AMDGPU_TEST_GPU_PATH}/driver"
if [[ ! -L "${driver}" ]]; then
  ln -s "${AMDGPU_TEST_ROOT}/sys/drivers/amdgpu" "${driver}"
fi
printf 'modprobe %s\n' "$*" >> "${AMDGPU_TEST_COMMAND_LOG}"
EOF

for command_name in depmod update-initramfs update-grub proxmox-boot-tool pve-efiboot-tool udevadm; do
  cat > "${STUB_BIN}/${command_name}" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${AMDGPU_TEST_COMMAND_LOG}"
EOF
done

cat > "${STUB_BIN}/update-initramfs" <<'EOF'
#!/usr/bin/env bash
printf 'update-initramfs %s\n' "$*" >> "${AMDGPU_TEST_COMMAND_LOG}"
if [[ "${AMDGPU_TEST_FAIL_INITRAMFS_ONCE:-0}" == 1 && ! -e "${AMDGPU_TEST_INITRAMFS_FAILURE_USED}" ]]; then
  touch "${AMDGPU_TEST_INITRAMFS_FAILURE_USED}"
  exit 23
fi
EOF

cat > "${STUB_BIN}/journalctl" <<'EOF'
#!/usr/bin/env bash
cat "${AMDGPU_TEST_JOURNAL_FILE}"
EOF

cat > "${STUB_BIN}/sha256sum" <<'EOF'
#!/usr/bin/env bash
target="${*: -1}"
if [[ -n "${AMDGPU_TEST_DRIFT_PATH:-}" && "${target}" == "${AMDGPU_TEST_DRIFT_PATH}" ]]; then
  printf 'drifted  %s\n' "${target}"
else
  printf 'deadbeef  %s\n' "${target}"
fi
EOF

cat > "${STUB_BIN}/reboot" <<'EOF'
#!/usr/bin/env bash
printf 'reboot %s\n' "$*" >> "${AMDGPU_TEST_COMMAND_LOG}"
exit 99
EOF

chmod 0755 "${STUB_BIN}"/*

AMD_ENV=(
  "PATH=${STUB_BIN}:${PATH}"
  "PROXMOX_AMDGPU_TEST_ROOT=1"
  "PROXMOX_AMDGPU_ROOT=${FIXTURE}"
  "PROXMOX_AMDGPU_SETTLE_SECONDS=0"
  "AMDGPU_TEST_ROOT=${FIXTURE}"
  "AMDGPU_TEST_GPU_PATH=${GPU_PATH}"
  "AMDGPU_TEST_MODULE_READY=${MODULE_READY}"
  "AMDGPU_TEST_PVE_FIRMWARE_READY=${PVE_FIRMWARE_READY}"
  "AMDGPU_TEST_COMMAND_LOG=${COMMAND_LOG}"
  "AMDGPU_TEST_JOURNAL_FILE=${JOURNAL_FILE}"
  "AMDGPU_TEST_INITRAMFS_FAILURE_USED=${INITRAMFS_FAILURE_USED}"
)

check_output="$(env "${AMD_ENV[@]}" bash -s -- --check < "${RUNNER}")"
grep -Fq 'driver=amdgpu' <<< "${check_output}" || fail "healthy check omitted amdgpu binding"
grep -Fq 'temperature.edge=55.000C' <<< "${check_output}" || fail "healthy check omitted temperature"
expect_exit 1 env "${AMD_ENV[@]}" AMDGPU_TEST_PVE_VERSION=8.4.0 bash -s -- --check < "${RUNNER}"
ok "streamed read-only check validates PVE 9, native binding, and temperatures"

: > "${COMMAND_LOG}"
blacklist_output="$(env "${AMD_ENV[@]}" bash -s -- --blacklist --yes < "${RUNNER}" 2>&1)"
BLACKLIST="${FIXTURE}/etc/modprobe.d/proxmox-amdgpu-blacklist.conf"
grep -qx 'blacklist amdgpu' "${BLACKLIST}" || fail "amdgpu blacklist entry is missing"
grep -qx 'blacklist radeon' "${BLACKLIST}" || fail "radeon blacklist entry is missing"
grep -Fq 'Reboot when convenient' <<< "${blacklist_output}" || fail "blacklist did not provide a soft reboot message"
grep -Fq 'update-initramfs -u -k 6.14.11-4-pve' "${COMMAND_LOG}" || fail "blacklist did not refresh initramfs"
if grep -q '^reboot ' "${COMMAND_LOG}"; then
  fail "runner attempted to reboot automatically"
fi
rm -f "${GPU_PATH}/driver"
ln -s "${FIXTURE}/sys/drivers/vfio-pci" "${GPU_PATH}/driver"
env "${AMD_ENV[@]}" bash -s -- --blacklist --yes < "${RUNNER}" >/dev/null
env "${AMD_ENV[@]}" bash -s -- --unblacklist --yes < "${RUNNER}" >/dev/null
[[ ! -e "${BLACKLIST}" ]] || fail "unblacklist left the managed file behind"
ok "streamed blacklist is explicit, reversible, idempotent, and never reboots"

: > "${COMMAND_LOG}"
rm -f "${MODULE_READY}" "${GPU_PATH}/driver" "${FIXTURE}/lib/firmware/amdgpu/test.bin"
printf '%s\n' 'amdgpu 0000:18:00.0: Direct firmware load for amdgpu/test.bin failed with error -2' > "${JOURNAL_FILE}"
repair_output="$(env "${AMD_ENV[@]}" bash -s < "${RUNNER}" 2>&1)"
[[ -e "${MODULE_READY}" ]] || fail "kernel package repair did not restore the module fixture"
[[ -e "${FIXTURE}/lib/firmware/amdgpu/test.bin" ]] || fail "missing firmware was not extracted"
grep -Fq 'apt-get -s install --reinstall proxmox-kernel-6.14.11-4-pve-signed pve-firmware' "${COMMAND_LOG}" \
  || fail "repair did not simulate the exact PVE kernel and firmware transaction"
grep -Fq 'apt-get download firmware-amd-graphics' "${COMMAND_LOG}" \
  || fail "repair did not download the Debian firmware archive"
if grep -E 'apt-get .*install.*firmware-amd-graphics' "${COMMAND_LOG}" >/dev/null; then
  fail "repair attempted to install firmware-amd-graphics"
fi
grep -Fq 'Reboot when convenient' <<< "${repair_output}" || fail "repair did not provide a soft reboot message"
grep -Fq "${FIXTURE}/lib/firmware/amdgpu/test.bin|deadbeef" \
  "${FIXTURE}/var/lib/proxmox-amdgpu-runner/firmware.manifest" \
  || fail "repair did not persist firmware provenance"
ok "repair restores the exact PVE module and safely extracts a named missing blob"

rm -f "${MODULE_READY}" "${GPU_PATH}/driver"
: > "${COMMAND_LOG}"
expect_exit 1 env "${AMD_ENV[@]}" AMDGPU_TEST_APT_CONFLICT=1 bash -s < "${RUNNER}"
if grep -Fq 'apt-get -y install' "${COMMAND_LOG}"; then
  fail "APT mutation ran after a protected-package simulation conflict"
fi
touch "${MODULE_READY}"
ln -s "${FIXTURE}/sys/drivers/vfio-pci" "${GPU_PATH}/driver"
expect_exit 1 env "${AMD_ENV[@]}" bash -s < "${RUNNER}"
ok "protected package removal and unrecorded VFIO ownership fail closed"

printf '%s\n' 'hostpci0: 0000:18:00.0,pcie=1' > "${FIXTURE}/etc/pve/qemu-server/100.conf"
write_passthrough_state
: > "${COMMAND_LOG}"
dry_run_output="$(env "${AMD_ENV[@]}" bash -s -- --dry-run < "${RUNNER}" 2>&1)"
grep -Fq 'dry-run complete' <<< "${dry_run_output}" || fail "takeover preview did not report completion"
[[ -e "${PASSTHROUGH_STATE}" && -e "${PT_BLACKLIST}" && -e "${PT_SCRIPT}" ]] \
  || fail "takeover preview changed repository-managed state"
[[ ! -s "${COMMAND_LOG}" ]] || fail "takeover preview invoked a mutating command"

takeover_output="$(env "${AMD_ENV[@]}" bash -s < "${RUNNER}" 2>&1)"
grep -Fq 'REBOOT REQUIRED' <<< "${takeover_output}" || fail "native takeover omitted the reboot gate"
grep -Fq 'VM passthrough configuration is intentionally unchanged' <<< "${takeover_output}" \
  || fail "native takeover omitted the VM-impact warning"
[[ ! -e "${PASSTHROUGH_STATE}" ]] || fail "completed takeover left active passthrough host state"
for restored_path in "${PT_MODULES}" "${PT_BLACKLIST}" "${PT_GRUB}" "${PT_HOOK}" "${PT_SCRIPT}"; do
  [[ ! -e "${restored_path}" ]] || fail "takeover left repository-managed path active: ${restored_path}"
done
grep -qx 'quiet' "${PT_CMDLINE}" || fail "takeover did not restore the original kernel command line"
[[ "$(basename "$(readlink "${GPU_PATH}/driver")")" == vfio-pci ]] \
  || fail "takeover rebound the live VFIO device"
grep -qx 'hostpci0: 0000:18:00.0,pcie=1' "${FIXTURE}/etc/pve/qemu-server/100.conf" \
  || fail "takeover changed VM configuration"
grep -Fq 'update-grub ' "${COMMAND_LOG}" || fail "takeover did not refresh GRUB"
grep -Fq 'update-initramfs -u -k all' "${COMMAND_LOG}" || fail "takeover did not rebuild all initramfs images"
find "${FIXTURE}/var/lib/proxmox-amdgpu-runner/native-takeover" -name complete -type f -print -quit | grep -q . \
  || fail "takeover did not archive completed rollback evidence"
if grep -q '^reboot ' "${COMMAND_LOG}"; then
  fail "takeover attempted to reboot automatically"
fi
ok "recorded VFIO state is restored transactionally without touching live ownership or VMs"

rm -f "${GPU_PATH}/driver"
ln -s "${FIXTURE}/sys/drivers/amdgpu" "${GPU_PATH}/driver"
check_output="$(env "${AMD_ENV[@]}" bash -s -- --check < "${RUNNER}")"
grep -Fq 'driver=amdgpu' <<< "${check_output}" || fail "post-reboot check omitted native binding"
grep -Fq 'temperature.edge=55.000C' <<< "${check_output}" || fail "post-reboot check omitted temperature"
ok "simulated operator reboot reaches native AMDGPU temperature verification"

rm -f "${GPU_PATH}/driver"
ln -s "${FIXTURE}/sys/drivers/vfio-pci" "${GPU_PATH}/driver"
write_passthrough_state
: > "${COMMAND_LOG}"
expect_exit 1 env "${AMD_ENV[@]}" AMDGPU_TEST_DRIFT_PATH="${PT_BLACKLIST}" bash -s < "${RUNNER}"
[[ -e "${PASSTHROUGH_STATE}" && -e "${PT_BLACKLIST}" ]] \
  || fail "drift rejection changed repository-managed state"
[[ ! -s "${COMMAND_LOG}" ]] || fail "drift rejection invoked a mutating command"

write_passthrough_state
rm -f "${PASSTHROUGH_TX}/kernel_cmdline"
: > "${COMMAND_LOG}"
expect_exit 1 env "${AMD_ENV[@]}" bash -s < "${RUNNER}"
[[ -e "${PASSTHROUGH_STATE}" && -e "${PT_BLACKLIST}" ]] \
  || fail "missing-backup rejection changed repository-managed state"
[[ ! -s "${COMMAND_LOG}" ]] || fail "missing-backup rejection invoked a mutating command"
ok "checksum drift and missing backups fail before mutation"

write_passthrough_state
rm -f "${INITRAMFS_FAILURE_USED}"
: > "${COMMAND_LOG}"
expect_exit 1 env "${AMD_ENV[@]}" AMDGPU_TEST_FAIL_INITRAMFS_ONCE=1 bash -s < "${RUNNER}"
[[ -e "${PASSTHROUGH_STATE}" && -e "${PT_MODULES}" && -e "${PT_BLACKLIST}" \
  && -e "${PT_GRUB}" && -e "${PT_HOOK}" && -e "${PT_SCRIPT}" ]] \
  || fail "failed boot refresh did not restore prepared passthrough state"
grep -qx 'quiet amd_iommu=on' "${PT_CMDLINE}" \
  || fail "failed boot refresh did not restore the prepared kernel command line"
[[ "$(grep -c '^update-initramfs -u -k all$' "${COMMAND_LOG}")" -eq 2 ]] \
  || fail "failed boot refresh did not rebuild initramfs during rollback"
ok "post-mutation boot failure rolls the complete host transaction back"

rm -rf "${PASSTHROUGH_ROOT}"
rm -f "${PT_MODULES}" "${PT_BLACKLIST}" "${PT_GRUB}" "${PT_HOOK}" "${PT_SCRIPT}"
printf '%s\n' 'blacklist amdgpu' > "${FIXTURE}/etc/modprobe.d/foreign-amd.conf"
rm -f "${GPU_PATH}/driver"
ln -s "${FIXTURE}/sys/drivers/amdgpu" "${GPU_PATH}/driver"
expect_exit 1 env "${AMD_ENV[@]}" bash -s < "${RUNNER}"
rm -f "${FIXTURE}/etc/modprobe.d/foreign-amd.conf" "${GPU_PATH}/driver"
ln -s "${FIXTURE}/sys/drivers/vfio-pci" "${GPU_PATH}/driver"
expect_exit 1 env "${AMD_ENV[@]}" bash -s < "${RUNNER}"
ok "foreign blacklists and VFIO ownership without valid repository state fail closed"

if grep -Eq '^[[:space:]]*(reboot|shutdown)([[:space:]]|$)' "${RUNNER}"; then
  fail "runner source contains an automatic reboot or shutdown command"
fi
if grep -Eq '(^|[[:space:]])qm[[:space:]]' "${RUNNER}" || grep -Fq '/etc/pve/' "${RUNNER}"; then
  fail "native AMDGPU runner must not inspect or mutate VM configuration"
fi
printf '[validate.gpu.amd] all AMDGPU runner contracts passed\n'
