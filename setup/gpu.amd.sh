#!/usr/bin/env bash
# Native AMDGPU repair and optional host-driver blacklist for Proxmox VE 9.
set -euo pipefail

COMPONENT="setup.gpu.amd"
ACTION="setup"
YES=0
DRY_RUN=0
ROOT_PREFIX="${PROXMOX_AMDGPU_ROOT:-}"
SYSFS_ROOT="${PROXMOX_AMDGPU_SYSFS_ROOT:-${ROOT_PREFIX}/sys}"
OS_RELEASE_PATH="${PROXMOX_AMDGPU_OS_RELEASE_PATH:-${ROOT_PREFIX}/etc/os-release}"
STATE_DIR="${PROXMOX_AMDGPU_STATE_DIR:-${ROOT_PREFIX}/var/lib/proxmox-amdgpu-runner}"
BLACKLIST_PATH="${PROXMOX_AMDGPU_BLACKLIST_PATH:-${ROOT_PREFIX}/etc/modprobe.d/proxmox-amdgpu-blacklist.conf}"
PASSTHROUGH_STATE_ROOT="${PROXMOX_AMDGPU_PASSTHROUGH_STATE_ROOT:-${ROOT_PREFIX}/etc/ansible/proxmox/gpu-passthrough}"
PASSTHROUGH_HOST_STATE="${PROXMOX_AMDGPU_PASSTHROUGH_HOST_STATE:-${PASSTHROUGH_STATE_ROOT}/host.state}"
PASSTHROUGH_BLACKLIST_PATH="${ROOT_PREFIX}/etc/modprobe.d/proxmox-gpu-passthrough-blacklist.conf"
SETTLE_SECONDS="${PROXMOX_AMDGPU_SETTLE_SECONDS:-1}"
TMP_ROOT=""
PVE_VERSION=""
KERNEL_RELEASE=""
TAKEOVER_REQUIRED=0
TAKEOVER_BOOTLOADER=""
TAKEOVER_ARCHIVE=""
TAKEOVER_MUTATED=0
OWN_BLACKLIST_REMOVE=0
AMD_DEVICES=()
MISSING_FIRMWARE=()
PASSTHROUGH_MANAGED_KEYS=(
  modules
  blacklist
  grub_dropin
  kernel_cmdline
  initramfs_hook
  initramfs_script
)

log() {
  printf '[%s] %s\n' "${COMPONENT}" "$*"
}

warn() {
  printf '[%s][warning] %s\n' "${COMPONENT}" "$*" >&2
}

die() {
  printf '[%s][error] %s\n' "${COMPONENT}" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  wget -qO- https://devs-guide.github.io/proxmox/setup.gpu.amd.sh | sudo bash
  wget -qO- https://devs-guide.github.io/proxmox/setup.gpu.amd.sh | sudo bash -s -- --dry-run
  wget -qO- https://devs-guide.github.io/proxmox/setup.gpu.amd.sh | sudo bash -s -- --check
  wget -qO- https://devs-guide.github.io/proxmox/setup.gpu.amd.sh | sudo bash -s -- --blacklist --yes
  wget -qO- https://devs-guide.github.io/proxmox/setup.gpu.amd.sh | sudo bash -s -- --unblacklist --yes

The default action restores valid repository-managed VFIO host state before
repairing native AMDGPU. VM configuration is not changed. The runner never
rebinds a live VFIO device or reboots the host.
EOF
}

cleanup() {
  if [[ -n "${TMP_ROOT}" && -d "${TMP_ROOT}" ]]; then
    rm -rf "${TMP_ROOT}"
  fi
}
trap cleanup EXIT INT TERM

while (($#)); do
  case "$1" in
    --check)
      [[ "${ACTION}" == setup ]] || die "choose only one action"
      ACTION="check"
      shift
      ;;
    --blacklist)
      [[ "${ACTION}" == setup ]] || die "choose only one action"
      ACTION="blacklist"
      shift
      ;;
    --unblacklist)
      [[ "${ACTION}" == setup ]] || die "choose only one action"
      ACTION="unblacklist"
      shift
      ;;
    --yes)
      YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if ((DRY_RUN == 1)) && [[ "${ACTION}" != setup ]]; then
  die "--dry-run is supported only by the default setup action"
fi

require.command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

require.root() {
  if [[ "${PROXMOX_AMDGPU_TEST_ROOT:-0}" == 1 ]]; then
    return
  fi
  [[ "$(id -u)" == 0 ]] || die "${ACTION} must run from a privileged shell"
}

platform.validate() {
  local codename=""
  local pve_output=""

  require.command pveversion
  [[ -r "${OS_RELEASE_PATH}" ]] || die "cannot read ${OS_RELEASE_PATH}"
  codename="$(
    unset VERSION_CODENAME
    # os-release is a root-managed shell-compatible data file.
    . "${OS_RELEASE_PATH}"
    printf '%s\n' "${VERSION_CODENAME:-}"
  )"
  [[ "${codename}" == trixie ]] || die "Debian Trixie is required; detected ${codename:-unknown}"

  pve_output="$(pveversion 2>/dev/null || true)"
  PVE_VERSION="$(printf '%s\n' "${pve_output}" | sed -n 's#^pve-manager/\([^/[:space:]]*\).*#\1#p' | sed -n '1p')"
  case "${PVE_VERSION}" in
    9.*) ;;
    *) die "Proxmox VE 9 is required; detected ${PVE_VERSION:-unknown}" ;;
  esac

  KERNEL_RELEASE="$(uname -r)"
  case "${KERNEL_RELEASE}" in
    *-pve) ;;
    *) die "the running kernel is not a Proxmox VE kernel: ${KERNEL_RELEASE}" ;;
  esac
  log "platform=pve${PVE_VERSION} debian=trixie kernel=${KERNEL_RELEASE}"
}

devices.discover() {
  local device_path=""
  local vendor=""
  local class=""
  local paths=("${SYSFS_ROOT}"/bus/pci/devices/*)

  AMD_DEVICES=()
  for device_path in "${paths[@]}"; do
    [[ -d "${device_path}" && -r "${device_path}/vendor" && -r "${device_path}/class" ]] || continue
    vendor="$(sed -n '1p' "${device_path}/vendor")"
    class="$(sed -n '1p' "${device_path}/class")"
    [[ "${vendor}" == 0x1002 ]] || continue
    case "${class}" in
      0x03*) AMD_DEVICES+=("$(basename "${device_path}")") ;;
    esac
  done

  ((${#AMD_DEVICES[@]} > 0)) || die "no AMD display devices were detected"
}

device.driver() {
  local bdf="$1"
  local link="${SYSFS_ROOT}/bus/pci/devices/${bdf}/driver"
  if [[ -L "${link}" ]]; then
    basename "$(readlink "${link}")"
  else
    printf 'unbound\n'
  fi
}

module.available() {
  modinfo amdgpu >/dev/null 2>&1
}

native.check() {
  local ok=1
  local bdf=""
  local driver=""
  local boot_vga="0"
  local input=""
  local raw=""
  local label=""
  local readable=0
  local inputs=()

  if module.available; then
    log "kernel module amdgpu is available"
  else
    warn "kernel module amdgpu is unavailable"
    ok=0
  fi

  for bdf in "${AMD_DEVICES[@]}"; do
    driver="$(device.driver "${bdf}")"
    [[ -r "${SYSFS_ROOT}/bus/pci/devices/${bdf}/boot_vga" ]] \
      && boot_vga="$(sed -n '1p' "${SYSFS_ROOT}/bus/pci/devices/${bdf}/boot_vga")" \
      || boot_vga="0"
    log "gpu=${bdf} driver=${driver} boot_vga=${boot_vga}"
    if [[ "${driver}" != amdgpu ]]; then
      warn "${bdf} is not using amdgpu"
      ok=0
    fi

    readable=0
    inputs=("${SYSFS_ROOT}/bus/pci/devices/${bdf}"/hwmon/hwmon*/temp*_input)
    for input in "${inputs[@]}"; do
      [[ -r "${input}" ]] || continue
      raw="$(sed -n '1p' "${input}")"
      [[ "${raw}" =~ ^-?[0-9]+$ ]] || continue
      label="${input%_input}_label"
      if [[ -r "${label}" ]]; then
        label="$(sed -n '1p' "${label}")"
      else
        label="$(basename "${input}" _input)"
      fi
      printf '[%s] gpu=%s temperature.%s=%.3fC\n' \
        "${COMPONENT}" "${bdf}" "${label}" "$(awk -v value="${raw}" 'BEGIN { print value / 1000 }')"
      readable=1
    done
    if ((readable == 0)); then
      warn "${bdf} has no readable hwmon temperature"
      ok=0
    fi
  done

  ((ok == 1))
}

blacklist.scan() {
  local directory=""
  local hit=""
  local directories=("${ROOT_PREFIX}/etc/modprobe.d" "${ROOT_PREFIX}/usr/lib/modprobe.d")

  for directory in "${directories[@]}"; do
    [[ -d "${directory}" ]] || continue
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] || continue
      [[ "${hit%%:*}" == "${BLACKLIST_PATH}" ]] && continue
      warn "another AMD driver blacklist exists: ${hit}"
    done < <(grep -R -n -E '^[[:space:]]*blacklist[[:space:]]+(amdgpu|radeon)([[:space:]]|$)' "${directory}" 2>/dev/null || true)
  done

  if [[ -r "${ROOT_PREFIX}/proc/cmdline" ]] \
    && grep -Eq '(^|[[:space:]])(module_blacklist|modprobe\.blacklist)=[^[:space:]]*(amdgpu|radeon)' "${ROOT_PREFIX}/proc/cmdline"; then
    warn "the kernel command line also blacklists an AMD driver"
  fi
}

passthrough.path.for_key() {
  case "$1" in
    modules) printf '%s\n' "${ROOT_PREFIX}/etc/modules-load.d/proxmox-gpu-passthrough.conf" ;;
    blacklist) printf '%s\n' "${PASSTHROUGH_BLACKLIST_PATH}" ;;
    grub_dropin) printf '%s\n' "${ROOT_PREFIX}/etc/default/grub.d/proxmox-gpu-passthrough.cfg" ;;
    kernel_cmdline) printf '%s\n' "${ROOT_PREFIX}/etc/kernel/cmdline" ;;
    initramfs_hook) printf '%s\n' "${ROOT_PREFIX}/etc/initramfs-tools/hooks/proxmox-gpu-passthrough" ;;
    initramfs_script) printf '%s\n' "${ROOT_PREFIX}/etc/initramfs-tools/scripts/init-top/proxmox-gpu-passthrough" ;;
    *) return 1 ;;
  esac
}

file.checksum() {
  local output=""
  output="$(sha256sum -- "$1")"
  printf '%s\n' "${output%% *}"
}

passthrough.state.validate() {
  local format=""
  local transaction_dir=""
  local key=""
  local expected_path=""
  local count=""
  local original_existed=""
  local original_checksum=""
  local original_backup=""
  local applied_existed=""
  local applied_checksum=""
  local actual_checksum=""
  local bdf=""

  require.command jq
  require.command sha256sum
  [[ -f "${PASSTHROUGH_HOST_STATE}" && ! -L "${PASSTHROUGH_HOST_STATE}" ]] \
    || die "repository passthrough state is not a regular file: ${PASSTHROUGH_HOST_STATE}"
  jq -e '
    type == "object" and
    (.format | type) == "number" and
    (.original_files | type) == "array" and
    (.applied_files | type) == "array" and
    (.transaction_dir | type) == "string" and
    (.bootloader | type) == "string" and
    all(.original_files[]; (.key | type) == "string" and (.path | type) == "string" and
      (.existed | type) == "boolean" and (.checksum | type) == "string" and (.backup | type) == "string") and
    all(.applied_files[]; (.key | type) == "string" and (.path | type) == "string" and
      (.existed | type) == "boolean" and (.checksum | type) == "string")
  ' "${PASSTHROUGH_HOST_STATE}" >/dev/null \
    || die "repository passthrough state has an invalid schema"

  format="$(jq -r '.format' "${PASSTHROUGH_HOST_STATE}")"
  [[ "${format}" == 4 ]] || die "repository passthrough state schema ${format} is unsupported; expected 4"
  count="$(jq -r '.original_files | length' "${PASSTHROUGH_HOST_STATE}")"
  [[ "${count}" == "${#PASSTHROUGH_MANAGED_KEYS[@]}" ]] \
    || die "repository passthrough state does not cover every managed host path"
  count="$(jq -r '.applied_files | length' "${PASSTHROUGH_HOST_STATE}")"
  [[ "${count}" == "${#PASSTHROUGH_MANAGED_KEYS[@]}" ]] \
    || die "repository passthrough state has an incomplete applied-file manifest"

  jq -e '
    ([.blacklist_vendors[]? | tostring | ascii_downcase] | index("amd")) != null or
    ([.gpu_function_records[]?.vendor_id | tostring | ascii_downcase] | index("0x1002")) != null
  ' "${PASSTHROUGH_HOST_STATE}" >/dev/null \
    || die "repository passthrough state is not an AMD host transaction"

  transaction_dir="$(jq -r '.transaction_dir' "${PASSTHROUGH_HOST_STATE}")"
  case "${transaction_dir}" in
    "${PASSTHROUGH_STATE_ROOT}"/transactions/*) ;;
    *) die "repository passthrough transaction path is outside the managed state root" ;;
  esac
  [[ -d "${transaction_dir}" && ! -L "${transaction_dir}" ]] \
    || die "repository passthrough transaction directory is missing or unsafe: ${transaction_dir}"

  TAKEOVER_BOOTLOADER="$(jq -r '.bootloader' "${PASSTHROUGH_HOST_STATE}")"
  case "${TAKEOVER_BOOTLOADER}" in
    grub|proxmox-boot-tool|pve-efiboot-tool) ;;
    *) die "repository passthrough state has an unsupported bootloader: ${TAKEOVER_BOOTLOADER}" ;;
  esac

  for key in "${PASSTHROUGH_MANAGED_KEYS[@]}"; do
    expected_path="$(passthrough.path.for_key "${key}")"
    count="$(jq -r --arg key "${key}" --arg path "${expected_path}" \
      '[.original_files[] | select(.key == $key and .path == $path)] | length' \
      "${PASSTHROUGH_HOST_STATE}")"
    [[ "${count}" == 1 ]] || die "original-file state is not uniquely bounded for ${key}"
    count="$(jq -r --arg key "${key}" --arg path "${expected_path}" \
      '[.applied_files[] | select(.key == $key and .path == $path)] | length' \
      "${PASSTHROUGH_HOST_STATE}")"
    [[ "${count}" == 1 ]] || die "applied-file state is not uniquely bounded for ${key}"

    original_existed="$(jq -r --arg key "${key}" '.original_files[] | select(.key == $key) | .existed' "${PASSTHROUGH_HOST_STATE}")"
    original_checksum="$(jq -r --arg key "${key}" '.original_files[] | select(.key == $key) | .checksum' "${PASSTHROUGH_HOST_STATE}")"
    original_backup="$(jq -r --arg key "${key}" '.original_files[] | select(.key == $key) | .backup' "${PASSTHROUGH_HOST_STATE}")"
    [[ "${original_backup}" == "${transaction_dir}/${key}" ]] \
      || die "rollback backup for ${key} is outside its repository transaction"
    if [[ "${original_existed}" == true ]]; then
      [[ -f "${original_backup}" && ! -L "${original_backup}" ]] \
        || die "required repository rollback backup is missing or unsafe: ${original_backup}"
      [[ -n "${original_checksum}" ]] || die "rollback backup checksum is missing for ${key}"
      actual_checksum="$(file.checksum "${original_backup}")"
      [[ "${actual_checksum}" == "${original_checksum}" ]] \
        || die "repository rollback backup checksum drifted: ${original_backup}"
    fi

    applied_existed="$(jq -r --arg key "${key}" '.applied_files[] | select(.key == $key) | .existed' "${PASSTHROUGH_HOST_STATE}")"
    applied_checksum="$(jq -r --arg key "${key}" '.applied_files[] | select(.key == $key) | .checksum' "${PASSTHROUGH_HOST_STATE}")"
    if [[ "${applied_existed}" == true ]]; then
      [[ -f "${expected_path}" && ! -L "${expected_path}" ]] \
        || die "repository-managed host path is missing or unsafe: ${expected_path}"
      [[ -n "${applied_checksum}" ]] || die "applied checksum is missing for ${key}"
      actual_checksum="$(file.checksum "${expected_path}")"
      [[ "${actual_checksum}" == "${applied_checksum}" ]] \
        || die "repository-managed host path drifted: ${expected_path}"
    elif [[ -e "${expected_path}" || -L "${expected_path}" ]]; then
      die "repository-managed host path appeared outside the recorded transaction: ${expected_path}"
    fi
  done

  for bdf in "${AMD_DEVICES[@]}"; do
    if [[ "$(device.driver "${bdf}")" == vfio-pci ]]; then
      jq -e --arg bdf "${bdf}" '(.gpu_functions // []) | index($bdf) != null' \
        "${PASSTHROUGH_HOST_STATE}" >/dev/null \
        || die "${bdf} is owned by VFIO but is absent from the recoverable repository transaction"
    fi
  done
  TAKEOVER_REQUIRED=1
}

blacklist.validate_setup() {
  local directory=""
  local hit=""
  local hit_path=""
  local directories=("${ROOT_PREFIX}/etc/modprobe.d" "${ROOT_PREFIX}/usr/lib/modprobe.d")

  OWN_BLACKLIST_REMOVE=0
  if [[ -e "${BLACKLIST_PATH}" || -L "${BLACKLIST_PATH}" ]]; then
    [[ -f "${BLACKLIST_PATH}" && ! -L "${BLACKLIST_PATH}" ]] \
      || die "managed AMD blacklist is not a regular file: ${BLACKLIST_PATH}"
    grep -Fq '# Managed by setup.gpu.amd.sh' "${BLACKLIST_PATH}" \
      || die "refusing to remove unmanaged file ${BLACKLIST_PATH}"
    OWN_BLACKLIST_REMOVE=1
  fi

  for directory in "${directories[@]}"; do
    [[ -d "${directory}" ]] || continue
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] || continue
      hit_path="${hit%%:*}"
      case "${hit_path}" in
        "${BLACKLIST_PATH}") ;;
        "${PASSTHROUGH_BLACKLIST_PATH}")
          ((TAKEOVER_REQUIRED == 1)) \
            || die "repository AMD blacklist exists without recoverable host state: ${hit_path}"
          ;;
        *) die "unmanaged AMD driver blacklist must be reviewed manually: ${hit}" ;;
      esac
    done < <(grep -R -n -E '^[[:space:]]*blacklist[[:space:]]+(amdgpu|radeon)([[:space:]]|$)' "${directory}" 2>/dev/null || true)
  done

  if [[ -r "${ROOT_PREFIX}/proc/cmdline" ]] \
    && grep -Eq '(^|[[:space:]])(module_blacklist|modprobe\.blacklist)=[^[:space:]]*(amdgpu|radeon)' "${ROOT_PREFIX}/proc/cmdline"; then
    die "the running kernel command line contains an unmanaged AMD driver blacklist"
  fi
}

native.takeover.inspect() {
  local bdf=""
  local driver=""

  if [[ -e "${PASSTHROUGH_HOST_STATE}" || -L "${PASSTHROUGH_HOST_STATE}" ]]; then
    passthrough.state.validate
  fi
  blacklist.validate_setup

  for bdf in "${AMD_DEVICES[@]}"; do
    driver="$(device.driver "${bdf}")"
    case "${driver}" in
      unbound|amdgpu) ;;
      vfio-pci)
        ((TAKEOVER_REQUIRED == 1)) \
          || die "${bdf} is bound to vfio-pci without recoverable repository passthrough state"
        ;;
      *) die "${bdf} is bound to ${driver}; refusing to replace its current owner" ;;
    esac
  done
}

confirmation.require() {
  local prompt="$1"
  local response=""

  ((YES == 1)) && return
  [[ -t 0 ]] || die "${ACTION} requires --yes in a non-interactive shell"
  printf '[%s] %s Type YES to continue: ' "${COMPONENT}" "${prompt}" >&2
  read -r response
  [[ "${response}" == YES ]] || die "cancelled"
}

initramfs.update() {
  require.command update-initramfs
  update-initramfs -u -k "${KERNEL_RELEASE}"
}

initramfs.update_all() {
  command -v update-initramfs >/dev/null 2>&1 || return 1
  update-initramfs -u -k all
}

boot.refresh() {
  case "${TAKEOVER_BOOTLOADER}" in
    grub)
      command -v update-grub >/dev/null 2>&1 || return 1
      update-grub
      ;;
    proxmox-boot-tool|pve-efiboot-tool)
      command -v "${TAKEOVER_BOOTLOADER}" >/dev/null 2>&1 || return 1
      "${TAKEOVER_BOOTLOADER}" refresh
      ;;
    *)
      return 1
      ;;
  esac
}

file.replace_from() {
  local source="$1"
  local destination="$2"
  local temporary="${destination}.setup-gpu-amd.$$"

  [[ -f "${source}" && ! -L "${source}" ]] || return 1
  if [[ ! -d "$(dirname "${destination}")" ]]; then
    install -d -m 0755 "$(dirname "${destination}")" || return 1
  fi
  rm -f -- "${temporary}" || return 1
  cp -a -- "${source}" "${temporary}" || return 1
  mv -f -- "${temporary}" "${destination}" || return 1
}

native.takeover.rollback() {
  local key=""
  local path=""
  local applied_existed=""
  local rollback_ok=1

  warn "native takeover failed; restoring the repository-managed passthrough host files"
  for key in "${PASSTHROUGH_MANAGED_KEYS[@]}"; do
    path="$(passthrough.path.for_key "${key}")"
    applied_existed="$(jq -r --arg key "${key}" '.applied_files[] | select(.key == $key) | .existed' "${TAKEOVER_ARCHIVE}/host.state")"
    if [[ "${applied_existed}" == true ]]; then
      file.replace_from "${TAKEOVER_ARCHIVE}/current/${key}" "${path}" || rollback_ok=0
    else
      rm -f -- "${path}" || rollback_ok=0
    fi
  done
  if [[ -f "${TAKEOVER_ARCHIVE}/current/runner-blacklist" ]]; then
    file.replace_from "${TAKEOVER_ARCHIVE}/current/runner-blacklist" "${BLACKLIST_PATH}" || rollback_ok=0
  else
    rm -f -- "${BLACKLIST_PATH}" || rollback_ok=0
  fi
  file.replace_from "${TAKEOVER_ARCHIVE}/host.state" "${PASSTHROUGH_HOST_STATE}" || rollback_ok=0
  boot.refresh >/dev/null 2>&1 || rollback_ok=0
  initramfs.update_all >/dev/null 2>&1 || rollback_ok=0
  ((rollback_ok == 1))
}

native.takeover.apply_inner() {
  local stamp=""
  local key=""
  local path=""
  local original_existed=""
  local original_backup=""

  require.command cp
  require.command install
  require.command jq
  require.command mv
  require.command update-initramfs
  case "${TAKEOVER_BOOTLOADER}" in
    grub) require.command update-grub ;;
    proxmox-boot-tool|pve-efiboot-tool) require.command "${TAKEOVER_BOOTLOADER}" ;;
  esac
  [[ ! -L "${STATE_DIR}" ]] || return 1
  install -d -m 0700 "${STATE_DIR}/native-takeover" || return 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
  TAKEOVER_ARCHIVE="${STATE_DIR}/native-takeover/${stamp}-$$"
  install -d -m 0700 "${TAKEOVER_ARCHIVE}/current" || return 1
  cp -a -- "${PASSTHROUGH_HOST_STATE}" "${TAKEOVER_ARCHIVE}/host.state" || return 1

  for key in "${PASSTHROUGH_MANAGED_KEYS[@]}"; do
    path="$(passthrough.path.for_key "${key}")"
    if [[ -e "${path}" ]]; then
      cp -a -- "${path}" "${TAKEOVER_ARCHIVE}/current/${key}" || return 1
    fi
  done
  if ((OWN_BLACKLIST_REMOVE == 1)); then
    cp -a -- "${BLACKLIST_PATH}" "${TAKEOVER_ARCHIVE}/current/runner-blacklist" || return 1
  fi
  printf '%s\n' \
    'format=1' \
    "source=${PASSTHROUGH_HOST_STATE}" \
    "bootloader=${TAKEOVER_BOOTLOADER}" \
    'purpose=restore-native-amdgpu' \
    'vm_configuration_modified=0' > "${TAKEOVER_ARCHIVE}/manifest"
  [[ -s "${TAKEOVER_ARCHIVE}/manifest" ]] || return 1
  chmod 0600 "${TAKEOVER_ARCHIVE}/manifest" || return 1

  TAKEOVER_MUTATED=1
  for key in "${PASSTHROUGH_MANAGED_KEYS[@]}"; do
    path="$(passthrough.path.for_key "${key}")"
    original_existed="$(jq -r --arg key "${key}" '.original_files[] | select(.key == $key) | .existed' "${PASSTHROUGH_HOST_STATE}")"
    original_backup="$(jq -r --arg key "${key}" '.original_files[] | select(.key == $key) | .backup' "${PASSTHROUGH_HOST_STATE}")"
    if [[ "${original_existed}" == true ]]; then
      file.replace_from "${original_backup}" "${path}" || return 1
    else
      rm -f -- "${path}" || return 1
    fi
  done
  if ((OWN_BLACKLIST_REMOVE == 1)); then
    rm -f -- "${BLACKLIST_PATH}" || return 1
  fi

  boot.refresh || return 1
  initramfs.update_all || return 1
  rm -f -- "${PASSTHROUGH_HOST_STATE}" || return 1
  printf '%s\n' 'status=complete' > "${TAKEOVER_ARCHIVE}/complete" || return 1
  chmod 0600 "${TAKEOVER_ARCHIVE}/complete" || return 1
}

native.takeover.apply() {
  warn "restoring the complete repository-managed AMD passthrough host transaction"
  warn "VM passthrough configuration is intentionally unchanged and may stop working"
  if ! native.takeover.apply_inner; then
    if ((TAKEOVER_MUTATED == 0)); then
      die "native takeover validation archive failed before any host file was changed"
    fi
    if [[ -n "${TAKEOVER_ARCHIVE}" ]] && native.takeover.rollback; then
      die "native takeover failed; repository-managed passthrough host files were restored"
    fi
    die "native takeover failed and rollback was incomplete; review ${TAKEOVER_ARCHIVE:-the host state}"
  fi
  log "repository-managed AMD passthrough host state was archived at ${TAKEOVER_ARCHIVE}"
  log "REBOOT REQUIRED: reboot to activate the restored native AMDGPU boot state"
  log "After reboot: wget -qO- https://devs-guide.github.io/proxmox/setup.gpu.amd.sh | sudo bash -s -- --check"
}

kernel.package.resolve() {
  local kernel_image="${ROOT_PREFIX}/boot/vmlinuz-${KERNEL_RELEASE}"
  local owner=""
  local package=""

  [[ -e "${kernel_image}" ]] || die "running kernel image is missing: ${kernel_image}"
  owner="$(dpkg-query -S "${kernel_image}" 2>/dev/null || true)"
  owner="${owner%%$'\n'*}"
  package="${owner%%:*}"
  case "${package}" in
    proxmox-kernel-*) printf '%s\n' "${package}" ;;
    *) die "could not resolve the installed Proxmox kernel package for ${kernel_image}" ;;
  esac
}

package.installed() {
  local status=""
  status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null || true)"
  [[ "${status}" == ii* ]]
}

packages.repair() {
  local repair_kernel="$1"
  local repair_firmware="$2"
  local kernel_package=""
  local simulation=""
  local packages=()

  ((repair_kernel == 1 || repair_firmware == 1)) || return
  require.command apt-get
  require.command dpkg-query

  if ((repair_kernel == 1)); then
    kernel_package="$(kernel.package.resolve)"
    packages+=("${kernel_package}")
  fi
  if ((repair_firmware == 1)); then
    packages+=(pve-firmware)
  fi

  log "simulating package repair: ${packages[*]}"
  if ! simulation="$(apt-get -s install --reinstall "${packages[@]}" 2>&1)"; then
    printf '%s\n' "${simulation}" >&2
    die "APT simulation failed"
  fi
  if printf '%s\n' "${simulation}" | grep -Eq '^Remv (proxmox-ve|proxmox-default-kernel|pve-firmware|proxmox-kernel-)'; then
    printf '%s\n' "${simulation}" >&2
    die "APT simulation would remove protected Proxmox packages"
  fi

  log "repairing packages: ${packages[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get -y install --reinstall "${packages[@]}"
}

firmware.collect_missing() {
  local journal=""
  local rel=""
  local target=""

  MISSING_FIRMWARE=()
  command -v journalctl >/dev/null 2>&1 || return
  journal="$(journalctl -k -b --no-pager 2>/dev/null || true)"
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    case "${rel}" in
      amdgpu/*)
        case "/${rel}/" in
          *'/../'*|*'//'* ) die "unsafe firmware path reported by the kernel: ${rel}" ;;
        esac
        ;;
      *) continue ;;
    esac
    target="${ROOT_PREFIX}/lib/firmware/${rel}"
    [[ -e "${target}" || -e "${target}.zst" ]] && continue
    MISSING_FIRMWARE+=("${rel}")
  done < <(printf '%s\n' "${journal}" \
    | grep -Ei '(failed|error[ =:()-]*-2|ENOENT)' \
    | grep -oE 'amdgpu/[A-Za-z0-9._+/-]+' \
    | sort -u || true)
}

firmware.extract_missing() {
  local download_dir=""
  local extract_dir=""
  local package_name=""
  local firmware_root=""
  local rel=""
  local source=""
  local resolved=""
  local destination=""
  local checksum=""
  local manifest="${STATE_DIR}/firmware.manifest"
  local candidate=""
  local debs=()

  ((${#MISSING_FIRMWARE[@]} > 0)) || return
  require.command apt-get
  require.command dpkg-deb
  require.command realpath
  require.command sha256sum

  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-gpu-amd.XXXXXX")"
  download_dir="${TMP_ROOT}/download"
  extract_dir="${TMP_ROOT}/extract"
  mkdir -p "${download_dir}" "${extract_dir}"

  log "downloading firmware-amd-graphics as an archive only"
  (cd "${download_dir}" && apt-get download firmware-amd-graphics)
  for candidate in "${download_dir}"/firmware-amd-graphics_*.deb; do
    [[ -f "${candidate}" ]] || continue
    debs+=("${candidate}")
  done
  ((${#debs[@]} == 1)) || die "expected exactly one firmware-amd-graphics archive"
  package_name="$(dpkg-deb -f "${debs[0]}" Package)"
  [[ "${package_name}" == firmware-amd-graphics ]] || die "downloaded archive has unexpected package identity: ${package_name}"
  dpkg-deb -x "${debs[0]}" "${extract_dir}"
  firmware_root="$(realpath "${extract_dir}/lib/firmware")"

  install -d -m 0700 "${STATE_DIR}"
  touch "${manifest}"
  chmod 0600 "${manifest}"
  for rel in "${MISSING_FIRMWARE[@]}"; do
    source="${extract_dir}/lib/firmware/${rel}"
    destination="${ROOT_PREFIX}/lib/firmware/${rel}"
    if [[ ! -e "${source}" && -e "${source}.zst" ]]; then
      source="${source}.zst"
      destination="${destination}.zst"
    fi
    [[ -e "${source}" ]] || die "firmware-amd-graphics does not contain ${rel}"
    resolved="$(realpath "${source}")"
    case "${resolved}" in
      "${firmware_root}"/*) ;;
      *) die "firmware archive path escapes its extraction root: ${rel}" ;;
    esac
    [[ ! -e "${destination}" ]] || continue
    install -d -m 0755 "$(dirname "${destination}")"
    install -m 0644 "${resolved}" "${destination}"
    checksum="$(sha256sum "${destination}")"
    checksum="${checksum%% *}"
    printf '%s|%s\n' "${destination}" "${checksum}" >> "${manifest}"
    log "installed missing firmware ${destination}"
  done
}

setup.run() {
  local repair_kernel=0
  local repair_firmware=0
  local changed=0

  require.root
  require.command modinfo
  require.command modprobe
  require.command depmod
  require.command dpkg-query
  native.takeover.inspect

  module.available || repair_kernel=1
  package.installed pve-firmware || repair_firmware=1
  firmware.collect_missing
  ((${#MISSING_FIRMWARE[@]} == 0)) || repair_firmware=1

  if ((DRY_RUN == 1)); then
    ((repair_kernel == 0)) || log "dry-run: would reinstall the exact running Proxmox kernel package"
    ((repair_firmware == 0)) || log "dry-run: would reinstall pve-firmware and extract only named missing AMD blobs"
    ((TAKEOVER_REQUIRED == 0)) \
      || log "dry-run: would restore and archive the complete repository-managed passthrough host transaction"
    ((OWN_BLACKLIST_REMOVE == 0)) \
      || log "dry-run: would remove ${BLACKLIST_PATH}"
    log "dry-run complete; no files, packages, drivers, boot entries, or VM configuration were changed"
    return
  fi

  if ((repair_kernel == 1 || repair_firmware == 1)); then
    packages.repair "${repair_kernel}" "${repair_firmware}"
    depmod -a "${KERNEL_RELEASE}"
    changed=1
  fi
  module.available || die "amdgpu is still unavailable after repairing the PVE kernel"

  firmware.collect_missing
  if ((${#MISSING_FIRMWARE[@]} > 0)); then
    firmware.extract_missing
    changed=1
  fi

  if ((TAKEOVER_REQUIRED == 1)); then
    native.takeover.apply
    return
  fi

  if ((OWN_BLACKLIST_REMOVE == 1)); then
    rm -f -- "${BLACKLIST_PATH}"
    changed=1
    log "removed the managed AMD host-driver blacklist"
  fi

  if ! modprobe amdgpu; then
    warn "amdgpu could not bind in the current boot; checking for missing firmware"
  fi
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle || true
  elif [[ "${SETTLE_SECONDS}" != 0 ]]; then
    sleep "${SETTLE_SECONDS}"
  fi

  firmware.collect_missing
  if ((${#MISSING_FIRMWARE[@]} > 0)); then
    firmware.extract_missing
    changed=1
  fi
  if ((changed == 1)); then
    initramfs.update
  fi

  if native.check; then
    log "AMDGPU is ready"
  elif ((changed == 1)); then
    warn "repair completed, but the native driver is not ready in the current boot"
  else
    die "AMDGPU did not pass the native driver and temperature check"
  fi
  if ((changed == 1)); then
    log "Reboot when convenient, then stream the published endpoint again with --check"
  fi
}

blacklist.run() {
  local tmp=""
  local bdf=""
  local boot_vga="0"

  require.root
  if [[ -e "${BLACKLIST_PATH}" ]]; then
    if grep -Fq '# Managed by setup.gpu.amd.sh' "${BLACKLIST_PATH}"; then
      log "AMD host-driver blacklist is already configured"
      return
    fi
    die "refusing to overwrite unmanaged file ${BLACKLIST_PATH}"
  fi
  require.command modinfo
  native.check || die "all AMD GPUs must use amdgpu and expose temperatures before blacklisting"
  for bdf in "${AMD_DEVICES[@]}"; do
    if [[ -r "${SYSFS_ROOT}/bus/pci/devices/${bdf}/boot_vga" ]]; then
      boot_vga="$(sed -n '1p' "${SYSFS_ROOT}/bus/pci/devices/${bdf}/boot_vga")"
      [[ "${boot_vga}" != 1 ]] || warn "${bdf} is boot_vga; host display will be lost after reboot"
    fi
  done
  confirmation.require "This disables AMD host graphics after the next reboot."
  blacklist.scan

  install -d -m 0755 "$(dirname "${BLACKLIST_PATH}")"
  tmp="${BLACKLIST_PATH}.tmp.$$"
  printf '%s\n' \
    '# Managed by setup.gpu.amd.sh' \
    'blacklist amdgpu' \
    'blacklist radeon' > "${tmp}"
  chmod 0644 "${tmp}"
  mv "${tmp}" "${BLACKLIST_PATH}"
  initramfs.update
  log "AMD host drivers are blacklisted. Reboot when convenient to apply the change."
  log "VFIO setup and VM attachment remain separate: setup/vm/gpu.sh"
}

unblacklist.run() {
  require.root
  if [[ ! -e "${BLACKLIST_PATH}" ]]; then
    log "the managed AMD blacklist is already absent"
    return
  fi
  grep -Fq '# Managed by setup.gpu.amd.sh' "${BLACKLIST_PATH}" \
    || die "refusing to remove unmanaged file ${BLACKLIST_PATH}"
  confirmation.require "Remove the managed AMD host-driver blacklist."
  rm -f "${BLACKLIST_PATH}"
  initramfs.update
  log "Managed AMD blacklist removed. Reboot when convenient to restore native binding."
}

platform.validate
devices.discover

case "${ACTION}" in
  setup) setup.run ;;
  check)
    require.command modinfo
    native.check || exit 4
    ;;
  blacklist) blacklist.run ;;
  unblacklist) unblacklist.run ;;
esac
