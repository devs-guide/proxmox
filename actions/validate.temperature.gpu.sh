#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${ROOT}/cli/temperature/gpu.sh"
DISPATCHER="${ROOT}/setup/temperature.sh"
RUNNER="${ROOT}/setup/temperature/gpu.sh"
MANIFEST="${ROOT}/actions/pages.features.txt"
TMP_ROOT="$(mktemp -d)"
SYSFS_ROOT="${TMP_ROOT}/sys"
STUB_BIN="${TMP_ROOT}/bin"
trap 'rm -rf "${TMP_ROOT}"' EXIT

fail() {
  printf '[validate.temperature.gpu][error] %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '[validate.temperature.gpu][ok] %s\n' "$*"
}

expect_exit() {
  local expected="$1"
  shift
  local observed=0
  "$@" >/dev/null 2>&1 || observed=$?
  [[ "${observed}" -eq "${expected}" ]] \
    || fail "expected exit ${expected}, observed ${observed}: $*"
}

for file in "${CLI}" "${DISPATCHER}" "${RUNNER}"; do
  [[ -f "${file}" ]] || fail "missing temperature component: ${file#${ROOT}/}"
  bash -n "${file}" || fail "Bash syntax failed: ${file#${ROOT}/}"
done
grep -qx 'setup/temperature.sh|setup/temperature.sh|plain' "${MANIFEST}" \
  || fail "temperature dispatcher is absent from Pages manifest"
grep -qx 'setup/temperature/gpu.sh|setup/temperature/gpu.sh|feature' "${MANIFEST}" \
  || fail "GPU temperature runner is absent from Pages manifest"
grep -Fq '"temperature/gpu.sh"' "${RUNNER}" \
  || fail "GPU temperature wrapper does not declare its CLI dependency"
ok "published dispatcher, runner, and dependency declarations are valid"

make_gpu() {
  local bdf="$1" vendor="$2" device="$3" driver="$4" boot="$5" temp="$6"
  local path="${SYSFS_ROOT}/bus/pci/devices/${bdf}"
  mkdir -p "${path}/hwmon/hwmon0" "${path}/power" "${SYSFS_ROOT}/drivers/${driver}"
  printf '%s\n' 0x030000 > "${path}/class"
  printf '%s\n' "${vendor}" > "${path}/vendor"
  printf '%s\n' "${device}" > "${path}/device"
  printf '%s\n' 0x1028 > "${path}/subsystem_vendor"
  printf '%s\n' 0x0b0d > "${path}/subsystem_device"
  printf '%s\n' "${boot}" > "${path}/boot_vga"
  printf '%s\n' active > "${path}/power/runtime_status"
  printf '%s\n' on > "${path}/power/control"
  printf '%s\n' amdgpu > "${path}/hwmon/hwmon0/name"
  printf '%s\n' edge > "${path}/hwmon/hwmon0/temp1_label"
  printf '%s\n' "${temp}" > "${path}/hwmon/hwmon0/temp1_input"
  ln -s "../../../../drivers/${driver}" "${path}/driver"
}

make_gpu 0000:18:00.0 0x1002 0x67e3 amdgpu 0 55000
make_gpu 0000:3b:00.0 0x1002 0x744c amdgpu 0 62000
make_gpu 0000:5e:00.0 0x10de 0x2200 nouveau 0 48000

temperature_json="$(
  PROXMOX_TEMPERATURE_SYSFS_ROOT="${SYSFS_ROOT}" \
  PROXMOX_TEMPERATURE_SAMPLE_INTERVAL=0 \
  bash "${CLI}" --vendor amd --require-driver amdgpu --require-readable \
    --reject-boot-vga --samples 2 --output json
)"
jq -e '
  .schema_version == 2
  and .component == "gpu"
  and .gate.passed == true
  and (.devices | length) == 2
  and (.devices | all(.driver == "amdgpu" and .boot_vga == false))
  and (.devices | all(.sensors[0].samples | length == 2))
  and (.devices | all(.acquisition.power.wake_attempted == false))
  and ([.devices[].sensors[0].average] == [55,62])
' <<< "${temperature_json}" >/dev/null \
  || fail "AMD temperature JSON did not preserve driver, gate, and sampled Celsius evidence"
ok "readable AMD hwmon inputs produce stable sampled JSON evidence"

dispatcher_json="$(
  PROXMOX_TEMPERATURE_SYSFS_ROOT="${SYSFS_ROOT}" \
  PROXMOX_TEMPERATURE_SAMPLE_INTERVAL=0 \
  bash "${DISPATCHER}" --component gpu --vendor amd --require-driver amdgpu \
    --require-readable --reject-boot-vga --samples 1 --output json
)"
jq -e '.gate.passed == true and (.devices | length) == 2' <<< "${dispatcher_json}" >/dev/null \
  || fail "temperature dispatcher did not forward the GPU contract"
ok "temperature dispatcher forwards only the implemented GPU component"

mkdir -p "${STUB_BIN}"
cat > "${STUB_BIN}/sleep" <<'EOF'
#!/usr/bin/env bash
if [[ "$(tr -d '[:space:]' < "${TEMPERATURE_TEST_CONTROL}")" == on ]]; then
  printf '%s\n' 63000 > "${TEMPERATURE_TEST_INPUT}"
  printf '%s\n' active > "${TEMPERATURE_TEST_RUNTIME_STATUS}"
fi
EOF
chmod 0755 "${STUB_BIN}/sleep"
printf '%s\n' 'N/A' > "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/hwmon/hwmon0/temp1_input"
printf '%s\n' suspended > "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/power/runtime_status"
printf '%s\n' auto > "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/power/control"
wake_json="$(
  PATH="${STUB_BIN}:${PATH}" \
  TEMPERATURE_TEST_CONTROL="${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/power/control" \
  TEMPERATURE_TEST_INPUT="${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/hwmon/hwmon0/temp1_input" \
  TEMPERATURE_TEST_RUNTIME_STATUS="${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/power/runtime_status" \
  PROXMOX_TEMPERATURE_SYSFS_ROOT="${SYSFS_ROOT}" \
  PROXMOX_TEMPERATURE_SAMPLE_INTERVAL=0 \
  bash "${CLI}" --vendor amd --gpu 0000:3b:00.0 --require-driver amdgpu \
    --require-readable --samples 1 --output json
)"
jq -e '
  .gate.passed == true
  and .devices[0].sensors[0].samples == [63]
  and .devices[0].acquisition.power.wake_attempted == true
  and .devices[0].acquisition.power.wake_succeeded == true
  and .devices[0].acquisition.power.restored == true
  and .devices[0].acquisition.power.control_before == "auto"
  and .devices[0].acquisition.power.control_after == "auto"
  and ([.devices[0].acquisition.attempts[].phase] == ["initial","after_runtime_wake"])
' <<< "${wake_json}" >/dev/null || fail "runtime-suspended AMDGPU did not wake, sample, and restore"
grep -qx auto "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/power/control" \
  || fail "runtime wake did not restore the original power policy"
ok "runtime-suspended AMDGPU is temporarily resumed and restored"

printf '%s\n' 'N/A' > "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/hwmon/hwmon0/temp1_input"
printf '%s\n' active > "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/power/runtime_status"
failure_rc=0
failure_json="$(
  PROXMOX_TEMPERATURE_SYSFS_ROOT="${SYSFS_ROOT}" \
  PROXMOX_TEMPERATURE_SAMPLE_INTERVAL=0 \
  bash "${CLI}" --vendor amd --gpu 0000:3b:00.0 --require-driver amdgpu \
    --require-readable --samples 1 --output json
)" || failure_rc=$?
[[ "${failure_rc}" -eq 4 ]] || fail "active unreadable sensor did not fail with exit 4"
jq -e '
  .gate.passed == false
  and .devices[0].acquisition.power.wake_attempted == false
  and .devices[0].acquisition.attempts[0].readable == false
  and (.devices[0].acquisition.attempts[0].error | contains("non-numeric"))
' <<< "${failure_json}" >/dev/null || fail "unreadable sensor failure omitted acquisition diagnostics"
printf '%s\n' 62000 > "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/hwmon/hwmon0/temp1_input"
printf '%s\n' on > "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/power/control"
ok "active acquisition failures remain blocking and include read diagnostics"

ln -sfn ../../../../drivers/nouveau "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/driver"
expect_exit 4 env \
  "PROXMOX_TEMPERATURE_SYSFS_ROOT=${SYSFS_ROOT}" \
  "PROXMOX_TEMPERATURE_SAMPLE_INTERVAL=0" \
  bash "${CLI}" --vendor amd --require-driver amdgpu --require-readable \
    --reject-boot-vga --samples 1 --output json
ln -sfn ../../../../drivers/amdgpu "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/driver"
printf '%s\n' 1 > "${SYSFS_ROOT}/bus/pci/devices/0000:3b:00.0/boot_vga"
expect_exit 4 env \
  "PROXMOX_TEMPERATURE_SYSFS_ROOT=${SYSFS_ROOT}" \
  "PROXMOX_TEMPERATURE_SAMPLE_INTERVAL=0" \
  bash "${CLI}" --vendor amd --require-driver amdgpu --require-readable \
    --reject-boot-vga --samples 1 --output json
ok "wrong drivers and boot displays fail the read-only gate with exit 4"

printf '[validate.temperature.gpu] all temperature contracts passed\n'
