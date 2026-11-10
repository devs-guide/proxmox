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
GPU_PATH="${FIXTURE}/sys/bus/pci/devices/0000:18:00.0"
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

for command_name in depmod update-initramfs udevadm; do
  cat > "${STUB_BIN}/${command_name}" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${AMDGPU_TEST_COMMAND_LOG}"
EOF
done

cat > "${STUB_BIN}/journalctl" <<'EOF'
#!/usr/bin/env bash
cat "${AMDGPU_TEST_JOURNAL_FILE}"
EOF

cat > "${STUB_BIN}/sha256sum" <<'EOF'
#!/usr/bin/env bash
printf 'deadbeef  %s\n' "$1"
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
ok "protected package removal and existing VFIO ownership fail closed"

if grep -Eq '^[[:space:]]*(reboot|shutdown)([[:space:]]|$)' "${RUNNER}"; then
  fail "runner source contains an automatic reboot or shutdown command"
fi
printf '[validate.gpu.amd] all AMDGPU runner contracts passed\n'
