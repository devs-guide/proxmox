#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${ROOT}/cli/temperature/gpu.sh"
DISPATCHER="${ROOT}/setup/temperature.sh"
RUNNER="${ROOT}/setup/temperature/gpu.sh"
MANIFEST="${ROOT}/actions/pages.features.txt"
TMP_ROOT="$(mktemp -d)"
SYSFS_ROOT="${TMP_ROOT}/sys"
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
  mkdir -p "${path}/hwmon/hwmon0" "${SYSFS_ROOT}/drivers/${driver}"
  printf '%s\n' 0x030000 > "${path}/class"
  printf '%s\n' "${vendor}" > "${path}/vendor"
  printf '%s\n' "${device}" > "${path}/device"
  printf '%s\n' "${boot}" > "${path}/boot_vga"
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
  .schema_version == 1
  and .component == "gpu"
  and .gate.passed == true
  and (.devices | length) == 2
  and (.devices | all(.driver == "amdgpu" and .boot_vga == false))
  and (.devices | all(.sensors[0].samples | length == 2))
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
