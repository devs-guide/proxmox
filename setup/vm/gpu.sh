#!/usr/bin/env bash
# Prepare a Proxmox host for whole-GPU passthrough and attach one GPU to a VM.
set -Eeuo pipefail

GPU_COMPONENT="setup.vm.gpu"
ACTION="status"
VM_ID=""
GPU_INPUT=""
GPU_BDF=""
GPU_SLOT=""
GPU_QM_SLOT=""
PROFILE="compute"
HOSTPCI_INDEX="auto"
OUTPUT="human"
DRY_RUN=0
YES=0
START_VM=0
REBOOT_HOST=0
BLACKLIST_HOST_DRIVERS=0
ALLOW_HOST_DISPLAY_LOSS=0
ALLOW_GUEST_CONSOLE_LOSS=0

SYSFS_ROOT="${PROXMOX_GPU_SYSFS_ROOT:-/sys}"
PROC_ROOT="${PROXMOX_GPU_PROC_ROOT:-/proc}"
ETC_ROOT="${PROXMOX_GPU_ETC_ROOT:-/etc}"
PVE_ROOT="${PROXMOX_GPU_PVE_ROOT:-/etc/pve}"
STATE_ROOT="${PROXMOX_GPU_STATE_ROOT:-/etc/ansible/proxmox/gpu-passthrough}"
TEST_MODE="${PROXMOX_GPU_TEST_MODE:-0}"
BOOTLOADER_OVERRIDE="${PROXMOX_GPU_BOOTLOADER:-}"

MODULES_FILE="${ETC_ROOT}/modules-load.d/proxmox-gpu-passthrough.conf"
BLACKLIST_FILE="${ETC_ROOT}/modprobe.d/proxmox-gpu-passthrough-blacklist.conf"
GRUB_DROPIN="${ETC_ROOT}/default/grub.d/proxmox-gpu-passthrough.cfg"
KERNEL_CMDLINE="${ETC_ROOT}/kernel/cmdline"
INITRAMFS_HOOK="${ETC_ROOT}/initramfs-tools/hooks/proxmox-gpu-passthrough"
INITRAMFS_SCRIPT="${ETC_ROOT}/initramfs-tools/scripts/init-top/proxmox-gpu-passthrough"
HOST_STATE="${STATE_ROOT}/host.state"
LOCK_FILE="${STATE_ROOT}/feature.lock"

declare -a GPU_FUNCTIONS=()
PVE_MAJOR=""
CPU_VENDOR=""
IOMMU_FLAG=""
BOOTLOADER=""
VFIO_VIRQFD=0
TEST_FAILURES=0
TEST_CHECKS=0

log() {
  [[ "${OUTPUT}" == "human" ]] || return 0
  printf '[%s] %s\n' "${GPU_COMPONENT}" "$*" >&2
}

warn() {
  printf '[%s][warn] %s\n' "${GPU_COMPONENT}" "$*" >&2
}

die() {
  printf '[%s][error] %s\n' "${GPU_COMPONENT}" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: setup/vm/gpu.sh --action ACTION [options]

Initial whole-GPU passthrough workflow for Proxmox VE 6.4 and 9.x.

Actions:
  preflight  Read-only validation of one GPU and target VM
  prepare    Configure IOMMU, VFIO, exact-BDF early binding, and optional blacklist
  test       Post-reboot readiness test; --test is a shorthand for this action
  attach     Add the complete GPU slot to the lowest free hostpciN
  detach     Remove only the feature-owned hostpciN and restore the prior display
  status     Report managed host/device/VM state without changing it
  unprepare  Restore managed host boot/module configuration; requires --yes

Core flags:
  --vm VMID
  --gpu FULL_PCI_BDF       Example: 0000:18:00.0
  --profile PROFILE        macos|winos|linux|linuxOS|compute (default: compute)
  --hostpci-index auto|N   Default: auto
  --output human|json      JSON is available for test/status (default: human)
  --dry-run
  --yes
  --start                  Start the VM after a successful attach
  --test                   Shorthand for --action test

Host preparation flags:
  --blacklist-host-drivers Globally blacklist AMD/NVIDIA host display drivers
  --allow-host-display-loss
                            Required with global blacklisting or a boot-VGA GPU
  --reboot, --reset        Reboot the Proxmox host after prepare; requires --yes

Desktop attachment flags:
  --allow-guest-console-loss
                            Required for macOS/Windows/Linux primary-display profiles

Safe first run:
  setup/vm/gpu.sh --action preflight --vm 101 --gpu 0000:18:00.0 \
    --profile macos

Dedicated passthrough host preparation:
  setup/vm/gpu.sh --action prepare --gpu 0000:18:00.0 \
    --blacklist-host-drivers --allow-host-display-loss --yes --reboot

Post-reboot gate:
  setup/vm/gpu.sh --test --vm 101 --gpu 0000:18:00.0 --profile macos

Attach the GPU and disable the virtual display:
  setup/vm/gpu.sh --action attach --vm 101 --gpu 0000:18:00.0 \
    --profile macos --allow-guest-console-loss --yes

The blacklist is intentionally explicit: it affects every AMD/NVIDIA GPU on
the host. Exact-BDF initramfs binding still reserves only the selected slot.
EOF
}

require_value() {
  local flag="$1"
  local value="${2-}"
  [[ -n "${value}" ]] || die "${flag} requires a value"
}

while (($#)); do
  case "$1" in
    --action) require_value "$1" "${2-}"; ACTION="$2"; shift 2 ;;
    --vm) require_value "$1" "${2-}"; VM_ID="$2"; shift 2 ;;
    --gpu) require_value "$1" "${2-}"; GPU_INPUT="$2"; shift 2 ;;
    --profile) require_value "$1" "${2-}"; PROFILE="$2"; shift 2 ;;
    --hostpci-index) require_value "$1" "${2-}"; HOSTPCI_INDEX="$2"; shift 2 ;;
    --output) require_value "$1" "${2-}"; OUTPUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) YES=1; shift ;;
    --start) START_VM=1; shift ;;
    --test) ACTION="test"; shift ;;
    --blacklist-host-drivers) BLACKLIST_HOST_DRIVERS=1; shift ;;
    --allow-host-display-loss) ALLOW_HOST_DISPLAY_LOSS=1; shift ;;
    --allow-guest-console-loss) ALLOW_GUEST_CONSOLE_LOSS=1; shift ;;
    --reboot|--reset) REBOOT_HOST=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "${ACTION}" in
  preflight|prepare|test|attach|detach|status|unprepare) ;;
  *) die "unsupported action: ${ACTION}" ;;
esac

case "${PROFILE}" in
  macos|winos|linux|compute) ;;
  linuxOS) PROFILE="linux" ;;
  *) die "unsupported profile: ${PROFILE}" ;;
esac

case "${OUTPUT}" in
  human|json) ;;
  *) die "--output must be human or json" ;;
esac

[[ -z "${VM_ID}" || "${VM_ID}" =~ ^[1-9][0-9]*$ ]] || die "invalid VM ID: ${VM_ID}"
[[ "${HOSTPCI_INDEX}" == "auto" || "${HOSTPCI_INDEX}" =~ ^[0-9]+$ ]] || \
  die "--hostpci-index must be auto or a non-negative integer"
((REBOOT_HOST == 0)) || [[ "${ACTION}" == "prepare" || "${ACTION}" == "unprepare" ]] || \
  die "--reboot/--reset is valid only with prepare or unprepare"
((BLACKLIST_HOST_DRIVERS == 0)) || [[ "${ACTION}" == "prepare" ]] || \
  die "--blacklist-host-drivers is valid only with --action prepare"
((START_VM == 0)) || [[ "${ACTION}" == "attach" ]] || die "--start is valid only with attach"
[[ "${OUTPUT}" == "human" || "${ACTION}" == "test" || "${ACTION}" == "status" ]] || \
  die "--output json is currently supported only by test and status"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  [[ "${TEST_MODE}" == "1" || "${EUID}" -eq 0 ]] || die "run this action as root on the Proxmox host"
}

require_proxmox() {
  if [[ "${TEST_MODE}" == "1" ]]; then
    return 0
  fi
  command_exists pveversion || die "pveversion is missing; this runner requires Proxmox VE"
  [[ -d "${PVE_ROOT}" ]] || die "${PVE_ROOT} is missing; this runner requires Proxmox VE"
}

require_commands() {
  local command_name=""
  local missing=0
  for command_name in awk basename flock grep lspci qm readlink sed sort; do
    if ! command_exists "${command_name}"; then
      warn "missing required command: ${command_name}"
      missing=1
    fi
  done
  ((missing == 0)) || die "install the missing commands before continuing"
}

normalize_gpu() {
  local value=""

  value="$(printf '%s' "${GPU_INPUT}" | tr '[:upper:]' '[:lower:]')"

  [[ -n "${value}" ]] || die "--gpu is required for ${ACTION}"
  if [[ "${value}" =~ ^[0-9a-f]{2}:[0-9a-f]{2}(\.[0-7])?$ ]]; then
    value="0000:${value}"
  fi
  [[ "${value}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}(\.[0-7])?$ ]] || \
    die "invalid PCI address: ${GPU_INPUT}; expected 0000:18:00.0"

  if [[ "${value}" == *.* ]]; then
    GPU_BDF="${value}"
    GPU_SLOT="${value%.*}"
  else
    GPU_SLOT="${value}"
    GPU_BDF="${value}.0"
  fi
  GPU_QM_SLOT="${GPU_SLOT#0000:}"
}

discover_gpu_functions() {
  local device_path=""
  local -a discovered=()

  shopt -s nullglob
  discovered=("${SYSFS_ROOT}/bus/pci/devices/${GPU_SLOT}."*)
  shopt -u nullglob
  ((${#discovered[@]} > 0)) || die "no PCI functions found for ${GPU_SLOT} under ${SYSFS_ROOT}"

  GPU_FUNCTIONS=()
  while IFS= read -r device_path; do
    [[ -n "${device_path}" ]] || continue
    GPU_FUNCTIONS+=("$(basename "${device_path}")")
  done < <(printf '%s\n' "${discovered[@]}" | sort)

  local found=0
  local function_bdf=""
  for function_bdf in "${GPU_FUNCTIONS[@]}"; do
    [[ "${function_bdf}" == "${GPU_BDF}" ]] && found=1
  done
  ((found == 1)) || die "selected function ${GPU_BDF} does not exist"
}

device_class() {
  local bdf="$1"
  local class_file="${SYSFS_ROOT}/bus/pci/devices/${bdf}/class"
  [[ -r "${class_file}" ]] || return 1
  tr -d '\n' < "${class_file}"
}

device_driver() {
  local bdf="$1"
  local driver_link="${SYSFS_ROOT}/bus/pci/devices/${bdf}/driver"
  if [[ -L "${driver_link}" ]]; then
    basename "$(readlink "${driver_link}")"
  else
    printf 'unbound\n'
  fi
}

device_iommu_group() {
  local bdf="$1"
  local group_link="${SYSFS_ROOT}/bus/pci/devices/${bdf}/iommu_group"
  [[ -L "${group_link}" ]] || return 1
  basename "$(readlink "${group_link}")"
}

is_selected_function() {
  local candidate="$1"
  local selected=""
  for selected in "${GPU_FUNCTIONS[@]}"; do
    [[ "${candidate}" == "${selected}" ]] && return 0
  done
  return 1
}

validate_iommu_group() {
  local expected_group=""
  local group=""
  local bdf=""
  local member_path=""
  local member=""
  local class=""
  local group_devices=""

  for bdf in "${GPU_FUNCTIONS[@]}"; do
    group="$(device_iommu_group "${bdf}" || true)"
    [[ -n "${group}" ]] || die "${bdf} has no IOMMU group; enable IOMMU and reboot first"
    if [[ -z "${expected_group}" ]]; then
      expected_group="${group}"
    elif [[ "${group}" != "${expected_group}" ]]; then
      die "functions for ${GPU_SLOT} span IOMMU groups ${expected_group} and ${group}"
    fi
  done

  group_devices="${SYSFS_ROOT}/kernel/iommu_groups/${expected_group}/devices"
  [[ -d "${group_devices}" ]] || die "IOMMU group ${expected_group} has no device directory"

  shopt -s nullglob
  for member_path in "${group_devices}"/*; do
    member="$(basename "${member_path}")"
    is_selected_function "${member}" && continue
    class="$(device_class "${member}" || true)"
    case "${class}" in
      0x0604*) ;;
      *) die "IOMMU group ${expected_group} also contains unrelated endpoint ${member} (${class:-unknown class})" ;;
    esac
  done
  shopt -u nullglob

  printf '%s\n' "${expected_group}"
}

is_boot_vga() {
  local bdf=""
  local boot_file=""
  for bdf in "${GPU_FUNCTIONS[@]}"; do
    boot_file="${SYSFS_ROOT}/bus/pci/devices/${bdf}/boot_vga"
    [[ -r "${boot_file}" ]] || continue
    [[ "$(tr -d '\n' < "${boot_file}")" == "1" ]] && return 0
  done
  return 1
}

detect_platform() {
  local pve_output=""
  local efiboot_output=""

  pve_output="$(pveversion 2>/dev/null || true)"
  PVE_MAJOR="$(printf '%s\n' "${pve_output}" | sed -n 's|.*pve-manager/\([0-9][0-9]*\).*|\1|p' | head -n 1)"
  [[ -n "${PVE_MAJOR}" ]] || PVE_MAJOR="unknown"
  case "${PVE_MAJOR}" in
    6|9) ;;
    *) die "unsupported Proxmox VE major version: ${PVE_MAJOR}; this initial runner supports 6.4 and 9.x" ;;
  esac

  CPU_VENDOR="$(awk -F: '/vendor_id|CPU implementer/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "${PROC_ROOT}/cpuinfo" 2>/dev/null || true)"
  case "${CPU_VENDOR}" in
    GenuineIntel) IOMMU_FLAG="intel_iommu=on" ;;
    AuthenticAMD) IOMMU_FLAG="amd_iommu=on" ;;
    *) die "unsupported or unknown CPU vendor: ${CPU_VENDOR:-missing}" ;;
  esac

  if [[ -n "${BOOTLOADER_OVERRIDE}" ]]; then
    BOOTLOADER="${BOOTLOADER_OVERRIDE}"
  else
    efiboot_output="$(efibootmgr -v 2>/dev/null || true)"
    if printf '%s\n' "${efiboot_output}" | grep -qi 'systemd-boot'; then
      BOOTLOADER="systemd-boot"
    else
      BOOTLOADER="grub"
    fi
  fi
  case "${BOOTLOADER}" in
    grub|systemd-boot) ;;
    *) die "unsupported bootloader: ${BOOTLOADER}" ;;
  esac

  if [[ "${PVE_MAJOR}" =~ ^[0-9]+$ ]] && ((PVE_MAJOR <= 7)); then
    VFIO_VIRQFD=1
  elif command_exists modinfo && modinfo vfio_virqfd >/dev/null 2>&1; then
    VFIO_VIRQFD=1
  fi
}

vm_config() {
  qm config "${VM_ID}"
}

validate_vm() {
  local config=""
  local status=""
  local ha_config=""

  [[ -n "${VM_ID}" ]] || die "--vm is required for ${ACTION}"
  config="$(vm_config)" || die "VM ${VM_ID} does not exist on this node"
  status="$(qm status "${VM_ID}" 2>/dev/null || true)"
  [[ "${status}" == *"status: stopped"* ]] || die "VM ${VM_ID} must be stopped"
  printf '%s\n' "${config}" | grep -Eq '^machine: (pc-)?q35([,-]|$)' || \
    die "VM ${VM_ID} must use a Q35 machine type"

  if [[ "${PROFILE}" != "compute" ]]; then
    printf '%s\n' "${config}" | grep -q '^bios: ovmf$' || \
      die "desktop profile ${PROFILE} requires OVMF"
    printf '%s\n' "${config}" | grep -q '^efidisk0:' || \
      die "desktop profile ${PROFILE} requires an EFI disk"
  fi

  if command_exists ha-manager; then
    ha_config="$(ha-manager config 2>/dev/null || true)"
    if printf '%s\n' "${ha_config}" | grep -Eq "^[[:space:]]*vm:${VM_ID}([[:space:]]|$)"; then
      die "VM ${VM_ID} is HA-managed; raw node-local GPU passthrough is refused"
    fi
  fi
}

validate_assignment_conflicts() {
  local config_file=""
  local line=""
  local owner_vm=""
  local qemu_dir="${PVE_ROOT}/qemu-server"
  [[ -d "${qemu_dir}" ]] || return 0

  shopt -s nullglob
  for config_file in "${qemu_dir}"/*.conf; do
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      owner_vm="$(basename "${config_file}" .conf)"
      if [[ "${owner_vm}" != "${VM_ID:-}" ]]; then
        die "GPU ${GPU_QM_SLOT} is already referenced by VM ${owner_vm}: ${line}"
      fi
    done < <(grep -E "^hostpci[0-9]+: .*(${GPU_SLOT}|${GPU_QM_SLOT})([,.]|$)" "${config_file}" || true)
  done
  shopt -u nullglob
}

preflight() {
  local require_active_iommu="${1:-1}"
  local group=""
  require_root
  require_proxmox
  require_commands
  normalize_gpu
  discover_gpu_functions
  if device_iommu_group "${GPU_BDF}" >/dev/null 2>&1; then
    group="$(validate_iommu_group)"
  elif [[ "${require_active_iommu}" == "1" ]]; then
    die "${GPU_SLOT} has no active IOMMU group; run prepare and reboot first"
  else
    group="pending host reboot"
  fi
  validate_assignment_conflicts
  [[ -z "${VM_ID}" ]] || validate_vm

  if is_boot_vga && ((ALLOW_HOST_DISPLAY_LOSS == 0)); then
    die "${GPU_SLOT} is marked boot_vga; acknowledge out-of-band access with --allow-host-display-loss"
  fi

  log "GPU slot: ${GPU_SLOT}"
  log "Functions: ${GPU_FUNCTIONS[*]}"
  log "IOMMU group: ${group}"
  [[ -z "${VM_ID}" ]] || log "VM ${VM_ID}: stopped and compatible with profile ${PROFILE}"
}

state_value() {
  local key="$1"
  local file="${2:-${HOST_STATE}}"
  [[ -r "${file}" ]] || return 1
  sed -n "s/^${key}=//p" "${file}" | head -n 1
}

atomic_write() {
  local path="$1"
  local mode="$2"
  local content="$3"
  local temporary="${path}.tmp.$$"

  mkdir -p "$(dirname "${path}")"
  printf '%s' "${content}" > "${temporary}"
  chmod "${mode}" "${temporary}"
  mv -f "${temporary}" "${path}"
}

append_kernel_tokens() {
  local current="$1"
  shift
  local token=""
  local updated="${current}"
  for token in "$@"; do
    if [[ " ${updated} " != *" ${token} "* ]]; then
      updated="${updated:+${updated} }${token}"
    fi
  done
  printf '%s\n' "${updated}"
}

render_modules_file() {
  printf '%s\n' \
    '# Managed by setup/vm/gpu.sh' \
    'vfio' \
    'vfio_iommu_type1' \
    'vfio_pci'
  ((VFIO_VIRQFD == 0)) || printf '%s\n' 'vfio_virqfd'
}

render_initramfs_hook() {
  cat <<EOF
#!/bin/sh
# Managed by setup/vm/gpu.sh.
set -eu
PREREQ=""
prereqs() { echo "\${PREREQ}"; }
case "\${1:-}" in prereqs) prereqs; exit 0 ;; esac
. /usr/share/initramfs-tools/hook-functions
manual_add_modules vfio
manual_add_modules vfio_iommu_type1
manual_add_modules vfio_pci
EOF
  ((VFIO_VIRQFD == 0)) || printf '%s\n' 'manual_add_modules vfio_virqfd'
}

render_initramfs_script() {
  local bdf=""
  cat <<'EOF'
#!/bin/sh
# Managed by setup/vm/gpu.sh.
set -eu
PREREQ=""
prereqs() { echo "${PREREQ}"; }
case "${1:-}" in prereqs) prereqs; exit 0 ;; esac

modprobe vfio-pci
EOF
  for bdf in "${GPU_FUNCTIONS[@]}"; do
    cat <<EOF
if [ -e /sys/bus/pci/devices/${bdf}/driver_override ]; then
  echo vfio-pci > /sys/bus/pci/devices/${bdf}/driver_override
  if [ -L /sys/bus/pci/devices/${bdf}/driver ]; then
    echo ${bdf} > /sys/bus/pci/devices/${bdf}/driver/unbind
  fi
  echo ${bdf} > /sys/bus/pci/drivers_probe
fi
EOF
  done
}

render_blacklist_file() {
  cat <<'EOF'
# Managed by setup/vm/gpu.sh for a dedicated passthrough host.
# This intentionally prevents every AMD/NVIDIA display GPU from binding.
blacklist amdgpu
blacklist radeon
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF
}

render_host_state() {
  local functions_csv=""
  functions_csv="$(IFS=,; printf '%s' "${GPU_FUNCTIONS[*]}")"
  cat <<EOF
format=1
gpu_slot=${GPU_SLOT}
gpu_functions=${functions_csv}
pve_major=${PVE_MAJOR}
cpu_vendor=${CPU_VENDOR}
iommu_flag=${IOMMU_FLAG}
bootloader=${BOOTLOADER}
blacklist_host_drivers=${BLACKLIST_HOST_DRIVERS}
EOF
}

prepare_host() {
  local existing_slot=""
  local existing_blacklist=""
  local current_cmdline=""
  local updated_cmdline=""
  local modules_content=""
  local hook_content=""
  local script_content=""
  local blacklist_content=""
  local state_content=""
  local grub_content=""

  preflight 0
  detect_platform

  if ((BLACKLIST_HOST_DRIVERS == 1)); then
    ((ALLOW_HOST_DISPLAY_LOSS == 1 && YES == 1)) || \
      die "global driver blacklisting requires --allow-host-display-loss --yes"
  fi
  if is_boot_vga; then
    ((ALLOW_HOST_DISPLAY_LOSS == 1 && YES == 1)) || \
      die "preparing a boot-VGA device requires --allow-host-display-loss --yes"
  fi
  if ((REBOOT_HOST == 1 && YES == 0)); then
    die "--reboot/--reset requires --yes"
  fi

  if [[ -r "${HOST_STATE}" ]]; then
    existing_slot="$(state_value gpu_slot || true)"
    existing_blacklist="$(state_value blacklist_host_drivers || true)"
    [[ "${existing_slot}" == "${GPU_SLOT}" ]] || \
      die "managed host state already belongs to ${existing_slot}; unprepare is not available in this initial release"
    [[ "${existing_blacklist}" == "${BLACKLIST_HOST_DRIVERS}" ]] || \
      die "existing blacklist mode is ${existing_blacklist}; changing it requires manual review"
  fi

  modules_content="$(render_modules_file)"
  hook_content="$(render_initramfs_hook)"
  script_content="$(render_initramfs_script)"
  state_content="$(render_host_state)"
  if ((BLACKLIST_HOST_DRIVERS == 1)); then
    blacklist_content="$(render_blacklist_file)"
  fi

  if ((DRY_RUN == 1)); then
    log "DRY-RUN write ${MODULES_FILE}"
    log "DRY-RUN write ${INITRAMFS_HOOK}"
    log "DRY-RUN write ${INITRAMFS_SCRIPT} for ${GPU_FUNCTIONS[*]}"
    ((BLACKLIST_HOST_DRIVERS == 0)) || log "DRY-RUN write global blacklist ${BLACKLIST_FILE}"
    if [[ "${BOOTLOADER}" == "grub" ]]; then
      log "DRY-RUN write ${GRUB_DROPIN} with ${IOMMU_FLAG} iommu=pt"
      log "DRY-RUN run update-grub"
    else
      log "DRY-RUN append ${IOMMU_FLAG} iommu=pt to ${KERNEL_CMDLINE}"
      log "DRY-RUN run proxmox-boot-tool refresh"
    fi
    log "DRY-RUN run update-initramfs -u -k all"
    ((REBOOT_HOST == 0)) || log "DRY-RUN reboot host"
    return 0
  fi

  mkdir -p "${STATE_ROOT}"
  exec 9>"${LOCK_FILE}"
  flock -n 9 || die "another GPU passthrough mutation is active"

  atomic_write "${MODULES_FILE}" 0644 "${modules_content}"$'\n'
  atomic_write "${INITRAMFS_HOOK}" 0755 "${hook_content}"$'\n'
  atomic_write "${INITRAMFS_SCRIPT}" 0755 "${script_content}"$'\n'
  if ((BLACKLIST_HOST_DRIVERS == 1)); then
    atomic_write "${BLACKLIST_FILE}" 0644 "${blacklist_content}"$'\n'
  fi

  if [[ "${BOOTLOADER}" == "grub" ]]; then
    grub_content="# Managed by setup/vm/gpu.sh
GRUB_CMDLINE_LINUX_DEFAULT=\"\${GRUB_CMDLINE_LINUX_DEFAULT:-} ${IOMMU_FLAG} iommu=pt\"
"
    atomic_write "${GRUB_DROPIN}" 0644 "${grub_content}"
    update-grub
  else
    [[ -r "${KERNEL_CMDLINE}" ]] || die "systemd-boot kernel command line is missing: ${KERNEL_CMDLINE}"
    if [[ ! -e "${STATE_ROOT}/kernel.cmdline.before" ]]; then
      cp -p "${KERNEL_CMDLINE}" "${STATE_ROOT}/kernel.cmdline.before"
    fi
    current_cmdline="$(tr -d '\n' < "${KERNEL_CMDLINE}")"
    updated_cmdline="$(append_kernel_tokens "${current_cmdline}" "${IOMMU_FLAG}" iommu=pt)"
    atomic_write "${KERNEL_CMDLINE}" 0644 "${updated_cmdline}"$'\n'
    proxmox-boot-tool refresh
  fi

  update-initramfs -u -k all
  atomic_write "${HOST_STATE}" 0600 "${state_content}"$'\n'

  log "host preparation complete for ${GPU_SLOT}"
  log "a host reboot is required before attach"
  if ((REBOOT_HOST == 1)); then
    log "rebooting the Proxmox host now"
    reboot
  fi
}

check_result() {
  local passed="$1"
  local name="$2"
  local detail="$3"
  TEST_CHECKS=$((TEST_CHECKS + 1))
  if [[ "${passed}" == "1" ]]; then
    [[ "${OUTPUT}" != "human" ]] || printf '[%s][ok] %s: %s\n' "${GPU_COMPONENT}" "${name}" "${detail}"
  else
    TEST_FAILURES=$((TEST_FAILURES + 1))
    [[ "${OUTPUT}" != "human" ]] || printf '[%s][fail] %s: %s\n' "${GPU_COMPONENT}" "${name}" "${detail}"
  fi
}

test_readiness() {
  local configured_slot=""
  local cmdline=""
  local bdf=""
  local driver=""
  local drivers=""
  local group=""
  local vm_ready=1
  local ready="false"
  local state_blacklist=""

  require_root
  require_proxmox
  require_commands
  normalize_gpu
  discover_gpu_functions
  detect_platform

  configured_slot="$(state_value gpu_slot || true)"
  if [[ "${configured_slot}" == "${GPU_SLOT}" ]]; then
    check_result 1 managed-state "host state owns ${GPU_SLOT}"
  else
    check_result 0 managed-state "expected ${GPU_SLOT}, found ${configured_slot:-none}"
  fi

  for driver in "${MODULES_FILE}" "${INITRAMFS_HOOK}" "${INITRAMFS_SCRIPT}"; do
    if [[ -r "${driver}" ]] && grep -Fq 'Managed by setup/vm/gpu.sh' "${driver}"; then
      check_result 1 "config-$(basename "${driver}")" "feature-owned configuration is present"
    else
      check_result 0 "config-$(basename "${driver}")" "feature-owned configuration is missing"
    fi
  done
  for bdf in "${GPU_FUNCTIONS[@]}"; do
    if grep -Fq "${bdf}" "${INITRAMFS_SCRIPT}" 2>/dev/null; then
      check_result 1 "binding-${bdf}" "exact BDF is present in initramfs configuration"
    else
      check_result 0 "binding-${bdf}" "exact BDF is missing from initramfs configuration"
    fi
  done
  state_blacklist="$(state_value blacklist_host_drivers || true)"
  if [[ "${state_blacklist}" == "1" ]]; then
    if [[ -r "${BLACKLIST_FILE}" ]] \
      && grep -qx 'blacklist amdgpu' "${BLACKLIST_FILE}" \
      && grep -qx 'blacklist nvidia' "${BLACKLIST_FILE}"; then
      check_result 1 host-driver-blacklist "AMD/NVIDIA display blacklists are present"
    else
      check_result 0 host-driver-blacklist "managed global blacklist is incomplete"
    fi
  fi

  cmdline="$(tr -d '\n' < "${PROC_ROOT}/cmdline" 2>/dev/null || true)"
  if [[ " ${cmdline} " == *" ${IOMMU_FLAG} "* ]]; then
    check_result 1 iommu-parameter "${IOMMU_FLAG} is active"
  else
    check_result 0 iommu-parameter "${IOMMU_FLAG} is missing from /proc/cmdline"
  fi
  if [[ " ${cmdline} " == *" iommu=pt "* ]]; then
    check_result 1 iommu-passthrough "iommu=pt is active"
  else
    check_result 0 iommu-passthrough "iommu=pt is missing from /proc/cmdline"
  fi

  group="$(validate_iommu_group 2>/dev/null || true)"
  if [[ -n "${group}" ]]; then
    check_result 1 iommu-group "all functions are isolated in group ${group}"
  else
    check_result 0 iommu-group "group is absent, split, or contains unrelated endpoints"
  fi

  drivers="$(lsmod 2>/dev/null | awk 'NR > 1 {print $1}' || true)"
  for driver in vfio vfio_iommu_type1 vfio_pci; do
    if printf '%s\n' "${drivers}" | grep -qx "${driver}"; then
      check_result 1 "module-${driver}" "loaded"
    else
      check_result 0 "module-${driver}" "not loaded"
    fi
  done
  if ((VFIO_VIRQFD == 1)); then
    if printf '%s\n' "${drivers}" | grep -qx vfio_virqfd; then
      check_result 1 module-vfio_virqfd "loaded for PVE ${PVE_MAJOR}"
    else
      check_result 0 module-vfio_virqfd "not loaded for PVE ${PVE_MAJOR}"
    fi
  fi

  for bdf in "${GPU_FUNCTIONS[@]}"; do
    driver="$(device_driver "${bdf}")"
    if [[ "${driver}" == "vfio-pci" ]]; then
      check_result 1 "driver-${bdf}" "vfio-pci"
    else
      check_result 0 "driver-${bdf}" "expected vfio-pci, found ${driver}"
    fi
  done

  if [[ -n "${VM_ID}" ]]; then
    if (validate_vm) >/dev/null 2>&1; then
      check_result 1 vm-preflight "VM ${VM_ID} is stopped and compatible"
    else
      vm_ready=0
      check_result 0 vm-preflight "VM ${VM_ID} is absent, running, HA-managed, or incompatible"
    fi
  fi

  ((TEST_FAILURES == 0)) && ready="true"
  if [[ "${OUTPUT}" == "json" ]]; then
    printf '{"action":"test","ready":%s,"checks":%d,"failures":%d,"gpu":"%s","vm":%s,"profile":"%s","pve_major":"%s","bootloader":"%s"}\n' \
      "${ready}" "${TEST_CHECKS}" "${TEST_FAILURES}" "${GPU_SLOT}" "${VM_ID:-null}" \
      "${PROFILE}" "${PVE_MAJOR}" "${BOOTLOADER}"
  elif [[ "${ready}" == "true" ]]; then
    log "post-reboot test passed; host and VM are ready for attach"
  else
    warn "post-reboot test failed with ${TEST_FAILURES} failed check(s)"
  fi

  ((TEST_FAILURES == 0 && vm_ready == 1))
}

choose_hostpci_index() {
  local config="$1"
  local index=""
  if [[ "${HOSTPCI_INDEX}" != "auto" ]]; then
    if printf '%s\n' "${config}" | grep -q "^hostpci${HOSTPCI_INDEX}:"; then
      die "hostpci${HOSTPCI_INDEX} is already occupied on VM ${VM_ID}"
    fi
    printf '%s\n' "${HOSTPCI_INDEX}"
    return 0
  fi

  index=0
  while printf '%s\n' "${config}" | grep -q "^hostpci${index}:"; do
    index=$((index + 1))
  done
  printf '%s\n' "${index}"
}

attach_gpu() {
  local configured_slot=""
  local config=""
  local selected_index=""
  local hostpci_value=""
  local original_vga=""
  local vm_state=""
  local vm_state_file=""

  preflight
  detect_platform
  configured_slot="$(state_value gpu_slot || true)"
  [[ "${configured_slot}" == "${GPU_SLOT}" ]] || \
    die "host is not prepared for ${GPU_SLOT}; run prepare, reboot, and --test first"

  local bdf=""
  for bdf in "${GPU_FUNCTIONS[@]}"; do
    [[ "$(device_driver "${bdf}")" == "vfio-pci" ]] || \
      die "${bdf} is not bound to vfio-pci; run --test after reboot"
  done

  config="$(vm_config)"
  selected_index="$(choose_hostpci_index "${config}")"
  hostpci_value="${GPU_QM_SLOT},pcie=1"
  original_vga="$(printf '%s\n' "${config}" | sed -n 's/^vga: //p' | head -n 1)"
  [[ -n "${original_vga}" ]] || original_vga="__absent__"

  if [[ "${PROFILE}" != "compute" ]]; then
    ((ALLOW_GUEST_CONSOLE_LOSS == 1 && YES == 1)) || \
      die "desktop profile ${PROFILE} disables the virtual console; use --allow-guest-console-loss --yes"
    hostpci_value="${hostpci_value},x-vga=1"
  fi

  vm_state_file="${STATE_ROOT}/vm-${VM_ID}.state"
  vm_state="format=1
vm=${VM_ID}
gpu_slot=${GPU_SLOT}
hostpci_index=${selected_index}
original_vga=${original_vga}
profile=${PROFILE}
status=attaching
"

  if ((DRY_RUN == 1)); then
    log "DRY-RUN qm set ${VM_ID} -hostpci${selected_index} ${hostpci_value}"
    [[ "${PROFILE}" == "compute" ]] || log "DRY-RUN qm set ${VM_ID} -vga none"
    ((START_VM == 0)) || log "DRY-RUN qm start ${VM_ID}"
    return 0
  fi

  mkdir -p "${STATE_ROOT}"
  exec 9>"${LOCK_FILE}"
  flock -n 9 || die "another GPU passthrough mutation is active"
  [[ ! -e "${vm_state_file}" ]] || die "managed VM state already exists: ${vm_state_file}"
  atomic_write "${vm_state_file}" 0600 "${vm_state}"

  qm set "${VM_ID}" "-hostpci${selected_index}" "${hostpci_value}"
  if [[ "${PROFILE}" != "compute" ]]; then
    qm set "${VM_ID}" -vga none
  fi
  sed -i.bak 's/^status=attaching$/status=attached/' "${vm_state_file}"
  rm -f "${vm_state_file}.bak"

  log "attached ${GPU_SLOT} to VM ${VM_ID} as hostpci${selected_index}"
  if ((START_VM == 1)); then
    qm start "${VM_ID}"
    log "started VM ${VM_ID}; verify the physical display or guest driver"
  fi
}

detach_gpu() {
  local vm_state_file=""
  local state_vm=""
  local state_slot=""
  local selected_index=""
  local original_vga=""
  local config=""

  require_root
  require_proxmox
  require_commands
  [[ -n "${VM_ID}" ]] || die "--vm is required for detach"
  vm_state_file="${STATE_ROOT}/vm-${VM_ID}.state"
  [[ -r "${vm_state_file}" ]] || die "no feature-owned attachment state exists for VM ${VM_ID}"
  state_vm="$(state_value vm "${vm_state_file}" || true)"
  state_slot="$(state_value gpu_slot "${vm_state_file}" || true)"
  selected_index="$(state_value hostpci_index "${vm_state_file}" || true)"
  original_vga="$(state_value original_vga "${vm_state_file}" || true)"
  [[ "${state_vm}" == "${VM_ID}" && -n "${state_slot}" && "${selected_index}" =~ ^[0-9]+$ ]] || \
    die "managed VM state is incomplete or invalid: ${vm_state_file}"

  GPU_INPUT="${state_slot}"
  normalize_gpu
  config="$(vm_config)" || die "VM ${VM_ID} does not exist on this node"
  [[ "$(qm status "${VM_ID}" 2>/dev/null || true)" == *"status: stopped"* ]] || \
    die "VM ${VM_ID} must be stopped before detach"
  printf '%s\n' "${config}" | grep -Eq "^hostpci${selected_index}: .*(${GPU_SLOT}|${GPU_QM_SLOT})([,.]|$)" || \
    die "hostpci${selected_index} no longer matches feature-owned GPU ${GPU_SLOT}"

  if ((DRY_RUN == 1)); then
    log "DRY-RUN qm set ${VM_ID} -delete hostpci${selected_index}"
    if [[ "${original_vga}" == "__absent__" ]]; then
      log "DRY-RUN qm set ${VM_ID} -delete vga"
    else
      log "DRY-RUN qm set ${VM_ID} -vga ${original_vga}"
    fi
    return 0
  fi

  exec 9>"${LOCK_FILE}"
  flock -n 9 || die "another GPU passthrough mutation is active"
  qm set "${VM_ID}" -delete "hostpci${selected_index}"
  if [[ "${original_vga}" == "__absent__" ]]; then
    qm set "${VM_ID}" -delete vga
  else
    qm set "${VM_ID}" -vga "${original_vga}"
  fi
  rm -f "${vm_state_file}"
  log "detached ${GPU_SLOT} from VM ${VM_ID} and restored its prior display configuration"
}

require_managed_file() {
  local path="$1"
  [[ -e "${path}" ]] || return 0
  grep -Fq 'Managed by setup/vm/gpu.sh' "${path}" || \
    die "refusing to remove unowned configuration: ${path}"
}

unprepare_host() {
  local configured_slot=""
  local managed_vm_state=""
  local state_blacklist=""

  require_root
  require_proxmox
  require_commands
  ((YES == 1 || DRY_RUN == 1)) || die "unprepare requires --yes"
  [[ -r "${HOST_STATE}" ]] || die "no managed host preparation state exists"
  configured_slot="$(state_value gpu_slot || true)"
  [[ -n "${configured_slot}" ]] || die "managed host state has no GPU slot"
  if [[ -n "${GPU_INPUT}" ]]; then
    normalize_gpu
    [[ "${GPU_SLOT}" == "${configured_slot}" ]] || \
      die "requested ${GPU_SLOT} does not match managed GPU ${configured_slot}"
  else
    GPU_INPUT="${configured_slot}"
    normalize_gpu
  fi

  shopt -s nullglob
  for managed_vm_state in "${STATE_ROOT}"/vm-*.state; do
    die "detach the feature-owned VM attachment first: ${managed_vm_state}"
  done
  shopt -u nullglob
  VM_ID=""
  validate_assignment_conflicts
  detect_platform
  [[ "$(state_value bootloader || true)" == "${BOOTLOADER}" ]] || \
    die "bootloader changed since prepare; manual rollback review is required"
  state_blacklist="$(state_value blacklist_host_drivers || true)"

  require_managed_file "${MODULES_FILE}"
  require_managed_file "${INITRAMFS_HOOK}"
  require_managed_file "${INITRAMFS_SCRIPT}"
  [[ "${state_blacklist}" != "1" ]] || require_managed_file "${BLACKLIST_FILE}"
  [[ "${BOOTLOADER}" != "grub" ]] || require_managed_file "${GRUB_DROPIN}"

  if ((DRY_RUN == 1)); then
    log "DRY-RUN remove ${MODULES_FILE}"
    log "DRY-RUN remove ${INITRAMFS_HOOK}"
    log "DRY-RUN remove ${INITRAMFS_SCRIPT}"
    [[ "${state_blacklist}" != "1" ]] || log "DRY-RUN remove ${BLACKLIST_FILE}"
    if [[ "${BOOTLOADER}" == "grub" ]]; then
      log "DRY-RUN remove ${GRUB_DROPIN} and run update-grub"
    else
      log "DRY-RUN restore ${KERNEL_CMDLINE} from ${STATE_ROOT}/kernel.cmdline.before"
      log "DRY-RUN run proxmox-boot-tool refresh"
    fi
    log "DRY-RUN run update-initramfs -u -k all"
    ((REBOOT_HOST == 0)) || log "DRY-RUN reboot host"
    return 0
  fi

  exec 9>"${LOCK_FILE}"
  flock -n 9 || die "another GPU passthrough mutation is active"
  rm -f "${MODULES_FILE}" "${INITRAMFS_HOOK}" "${INITRAMFS_SCRIPT}"
  [[ "${state_blacklist}" != "1" ]] || rm -f "${BLACKLIST_FILE}"
  if [[ "${BOOTLOADER}" == "grub" ]]; then
    rm -f "${GRUB_DROPIN}"
    update-grub
  else
    [[ -r "${STATE_ROOT}/kernel.cmdline.before" ]] || \
      die "saved systemd-boot kernel command line is missing"
    cp -p "${STATE_ROOT}/kernel.cmdline.before" "${KERNEL_CMDLINE}"
    proxmox-boot-tool refresh
  fi
  update-initramfs -u -k all
  rm -f "${HOST_STATE}" "${STATE_ROOT}/kernel.cmdline.before"
  log "removed managed host preparation for ${GPU_SLOT}"
  log "a host reboot is required to restore normal driver ownership"
  if ((REBOOT_HOST == 1)); then
    log "rebooting the Proxmox host now"
    reboot
  fi
}

status_report() {
  local prepared="false"
  local configured_slot=""
  local bdf=""
  local driver=""
  local functions_json=""
  local separator=""
  local configured_json="null"
  local requested_json="null"

  require_root
  require_proxmox
  if [[ -n "${GPU_INPUT}" ]]; then
    normalize_gpu
    discover_gpu_functions
  elif [[ -r "${HOST_STATE}" ]]; then
    GPU_INPUT="$(state_value gpu_slot)"
    normalize_gpu
    discover_gpu_functions
  fi

  configured_slot="$(state_value gpu_slot || true)"
  [[ -z "${configured_slot}" ]] || prepared="true"
  if [[ "${OUTPUT}" == "json" ]]; then
    [[ -z "${configured_slot}" ]] || configured_json="\"${configured_slot}\""
    [[ -z "${GPU_SLOT}" ]] || requested_json="\"${GPU_SLOT}\""
    for bdf in "${GPU_FUNCTIONS[@]}"; do
      driver="$(device_driver "${bdf}")"
      functions_json+="${separator}{\"bdf\":\"${bdf}\",\"driver\":\"${driver}\"}"
      separator=","
    done
    printf '{"action":"status","prepared":%s,"configured_gpu":%s,"requested_gpu":%s,"vm":%s,"functions":[%s]}\n' \
      "${prepared}" "${configured_json}" "${requested_json}" \
      "${VM_ID:-null}" "${functions_json}"
    return 0
  fi

  if [[ "${prepared}" == "true" ]]; then
    log "managed host GPU: ${configured_slot}"
    log "global driver blacklist: $(state_value blacklist_host_drivers || printf unknown)"
  else
    log "managed host GPU: none"
  fi
  for bdf in "${GPU_FUNCTIONS[@]}"; do
    log "${bdf}: driver=$(device_driver "${bdf}") iommu_group=$(device_iommu_group "${bdf}" || printf none)"
  done
  if [[ -n "${VM_ID}" ]]; then
    qm status "${VM_ID}"
    qm config "${VM_ID}" | grep -E '^(bios|machine|efidisk0|vga|hostpci[0-9]+):' || true
  fi
}

case "${ACTION}" in
  preflight) preflight ;;
  prepare) prepare_host ;;
  test) test_readiness ;;
  attach) attach_gpu ;;
  detach) detach_gpu ;;
  status) status_report ;;
  unprepare) unprepare_host ;;
esac
