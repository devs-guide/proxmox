#!/usr/bin/env bash
# Native AMDGPU repair and optional host-driver blacklist for Proxmox VE 9.
set -euo pipefail

COMPONENT="setup.gpu.amd"
ACTION="setup"
YES=0
ROOT_PREFIX="${PROXMOX_AMDGPU_ROOT:-}"
SYSFS_ROOT="${PROXMOX_AMDGPU_SYSFS_ROOT:-${ROOT_PREFIX}/sys}"
OS_RELEASE_PATH="${PROXMOX_AMDGPU_OS_RELEASE_PATH:-${ROOT_PREFIX}/etc/os-release}"
STATE_DIR="${PROXMOX_AMDGPU_STATE_DIR:-${ROOT_PREFIX}/var/lib/proxmox-amdgpu-runner}"
BLACKLIST_PATH="${PROXMOX_AMDGPU_BLACKLIST_PATH:-${ROOT_PREFIX}/etc/modprobe.d/proxmox-amdgpu-blacklist.conf}"
SETTLE_SECONDS="${PROXMOX_AMDGPU_SETTLE_SECONDS:-1}"
TMP_ROOT=""
PVE_VERSION=""
KERNEL_RELEASE=""
AMD_DEVICES=()
MISSING_FIRMWARE=()

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
  setup.gpu.amd.sh                    Install or repair native AMDGPU support
  setup.gpu.amd.sh --check            Check AMDGPU binding and temperatures
  setup.gpu.amd.sh --blacklist --yes  Blacklist AMD host drivers
  setup.gpu.amd.sh --unblacklist --yes

The runner supports Proxmox VE 9 on Debian Trixie. It never reboots the host.
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

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
  local bdf=""
  local driver=""

  require.root
  require.command modinfo
  require.command modprobe
  require.command depmod
  blacklist.scan
  if [[ -e "${BLACKLIST_PATH}" ]]; then
    die "the managed AMD blacklist is active; run --unblacklist before native-driver repair"
  fi

  for bdf in "${AMD_DEVICES[@]}"; do
    driver="$(device.driver "${bdf}")"
    case "${driver}" in
      unbound|amdgpu) ;;
      *) die "${bdf} is bound to ${driver}; refusing to replace its current owner" ;;
    esac
  done

  module.available || repair_kernel=1
  package.installed pve-firmware || repair_firmware=1
  firmware.collect_missing
  ((${#MISSING_FIRMWARE[@]} == 0)) || repair_firmware=1
  if ((repair_kernel == 1 || repair_firmware == 1)); then
    packages.repair "${repair_kernel}" "${repair_firmware}"
    depmod -a "${KERNEL_RELEASE}"
    changed=1
  fi
  module.available || die "amdgpu is still unavailable after repairing the PVE kernel"

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
    log "Reboot when convenient, then rerun: sudo ./setup.gpu.amd.sh --check"
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
