#!/usr/bin/env bash
# Shared parser, platform detection, state, and JSON helpers for VM GPU runners.

GPU_COMPONENT="${GPU_COMPONENT:-cli.gpu}"
GPU_EXIT_USAGE=2
GPU_EXIT_ENVIRONMENT=3
GPU_EXIT_PREFLIGHT=4
GPU_EXIT_MUTATION=5
GPU_EXIT_ROLLBACK=6
GPU_EXIT_DEPENDENCY=10

ACTION="status"
ACTION_EXPLICIT=0
VM_ID=""
GPU_INPUT=""
GPU_BDF=""
GPU_SLOT=""
GPU_QM_SLOT=""
PROFILE="linux-compute"
HOSTPCI_INDEX="auto"
OUTPUT="human"
REQUESTED_RELEASE=""
EFFECTIVE_RELEASE=""
PVE_MAJOR=""
DEBIAN_CODENAME=""
PVE_VERSION=""
BINDING_REQUESTED="release"
BINDING_EFFECTIVE=""
DRY_RUN=0
YES=0
START_VM=0
REBOOT_HOST=0
BLACKLIST_HOST_DRIVERS=0
BLACKLIST_INPUT_MODE="none"
BLACKLIST_JSON_INPUT=""
BLACKLIST_VENDOR_INPUT=""
ALLOW_HOST_DISPLAY_LOSS=0
ALLOW_GUEST_CONSOLE_LOSS=0
PRIMARY_GPU=0
DISABLE_ONBOOT=0
IOMMU_PT=0
RESET_ALIAS_USED=0

SYSFS_ROOT="${PROXMOX_GPU_SYSFS_ROOT:-/sys}"
PROC_ROOT="${PROXMOX_GPU_PROC_ROOT:-/proc}"
ETC_ROOT="${PROXMOX_GPU_ETC_ROOT:-/etc}"
PVE_ROOT="${PROXMOX_GPU_PVE_ROOT:-/etc/pve}"
STATE_ROOT="${PROXMOX_GPU_STATE_ROOT:-/etc/ansible/proxmox/gpu-passthrough}"
LOCK_FILE="${PROXMOX_GPU_LOCK_FILE:-${STATE_ROOT}/feature.lock}"
TEST_MODE="${PROXMOX_GPU_TEST_MODE:-0}"
BOOTLOADER_OVERRIDE="${PROXMOX_GPU_BOOTLOADER:-}"
PLAYBOOK_ROOT="${PROXMOX_GPU_PLAYBOOK_ROOT:-}"

declare -a GPU_FUNCTIONS=()
declare -a SELECTED_GPU_SLOTS=()
declare -a BLACKLIST_GPU_INPUTS=()
SELECTION_SET_JSON='null'
BLACKLIST_POLICY_JSON='{"requested":false,"input_mode":"none","requested_vendors":[],"effective_vendors":[],"exact_bind_only_vendors":[],"requested_bdfs":[],"affected_bdfs":[],"affected_slots":[],"affected_function_bdfs":[]}'

gpu.log() {
  [[ "${OUTPUT}" == "human" ]] || return 0
  printf '[%s] %s\n' "${GPU_COMPONENT}" "$*" >&2
}

gpu.warn() {
  printf '[%s][warn] %s\n' "${GPU_COMPONENT}" "$*" >&2
}

gpu.die() {
  local code="$1"
  shift
  printf '[%s][error] %s\n' "${GPU_COMPONENT}" "$*" >&2
  exit "${code}"
}

gpu.command_exists() {
  command -v "$1" >/dev/null 2>&1
}

gpu.require_value() {
  local flag="$1"
  local value="${2-}"
  [[ -n "${value}" ]] || gpu.die "${GPU_EXIT_USAGE}" "${flag} requires a value"
}

gpu.select_action() {
  local selected="$1"
  if ((ACTION_EXPLICIT == 1)) && [[ "${ACTION}" != "${selected}" ]]; then
    gpu.die "${GPU_EXIT_USAGE}" "conflicting actions: ${ACTION} and ${selected}"
  fi
  ACTION="${selected}"
  ACTION_EXPLICIT=1
}

gpu.usage() {
  cat <<'EOF'
Usage: setup/vm/gpu.sh --action ACTION [options]

Version-aware whole-GPU passthrough for PVE 6.4/Buster and PVE 9.x/Trixie.

Actions:
  inventory   List GPU slots and their current host ownership
  preflight   Validate one GPU and optional target VM without changing state
  prepare     Apply only release-required host preparation
  verify      State-aware host, device, and VM readiness gate
  attach      Attach the complete GPU slot to one stopped QEMU VM
  detach      Remove only the feature-owned VM attachment
  status      Report managed and live state
  unprepare   Restore feature-managed host configuration

Compatibility action flags:
  --attach              Alias for --action attach
  --remove              Alias for --action detach; never unprepares the host
  --test                Alias for --action verify

Core options:
  --vm VMID
  --gpu PCI_BDF         Exact display function: 0000:18:00.0 or 18:00.0
  --release 6.4|9.1     Optional assertion; live detection always selects tooling
  --version VALUE       Alias for the release assertion
  --profile macos-desktop|windows-desktop|linux-desktop|linux-compute
  --hostpci-index auto|N
  --binding release|automatic|early
  --output human|json
  --dry-run
  --yes                 Required by mutating actions
  --start               Start the VM only after a successful attach
  --reboot              Reboot only after successful prepare/unprepare

Feature options:
  --primary-gpu
  --allow-guest-console-loss
  --disable-onboot
  --iommu-pt
  --blacklist [JSON]    JSON values: {"amd":"all"} or {"amd":["BDF",...]}
  --blacklist-all       Prepare and blacklist all inventoried AMD/NVIDIA GPUs
  --blacklist-amd       Prepare and blacklist every inventoried AMD GPU
  --blacklist-nvidia    Prepare and blacklist every inventoried NVIDIA GPU
  --blacklist-vendor amd|nvidia [--blacklist-gpu PCI_BDF ...]
  --blacklist-host-drivers
  --allow-host-display-loss

Safe first use:
  setup/vm/gpu.sh --action inventory --output json
  setup/vm/gpu.sh --action preflight --vm 101 --gpu 0000:18:00.0 \
    --profile linux-compute
EOF
}

gpu.parse_args() {
  while (($#)); do
    case "$1" in
      --action) gpu.require_value "$1" "${2-}"; gpu.select_action "$2"; shift 2 ;;
      --attach) gpu.select_action attach; shift ;;
      --remove) gpu.select_action detach; shift ;;
      --test) gpu.select_action verify; shift ;;
      --inventory) gpu.select_action inventory; shift ;;
      --unprepare) gpu.select_action unprepare; shift ;;
      --vm) gpu.require_value "$1" "${2-}"; VM_ID="$2"; shift 2 ;;
      --gpu) gpu.require_value "$1" "${2-}"; GPU_INPUT="$2"; shift 2 ;;
      --profile) gpu.require_value "$1" "${2-}"; PROFILE="$2"; shift 2 ;;
      --hostpci-index) gpu.require_value "$1" "${2-}"; HOSTPCI_INDEX="$2"; shift 2 ;;
      --output) gpu.require_value "$1" "${2-}"; OUTPUT="$2"; shift 2 ;;
      --release|--version) gpu.require_value "$1" "${2-}"; REQUESTED_RELEASE="$2"; shift 2 ;;
      --release=*|--version=*) REQUESTED_RELEASE="${1#*=}"; shift ;;
      --binding) gpu.require_value "$1" "${2-}"; BINDING_REQUESTED="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --yes) YES=1; shift ;;
      --start) START_VM=1; shift ;;
      --reboot) REBOOT_HOST=1; shift ;;
      --reset) REBOOT_HOST=1; RESET_ALIAS_USED=1; shift ;;
      --blacklist)
        [[ "${BLACKLIST_INPUT_MODE}" == none ]] || gpu.die "${GPU_EXIT_USAGE}" "conflicting blacklist selectors"
        BLACKLIST_HOST_DRIVERS=1
        if (($# > 1)) && [[ "${2-}" != --* ]]; then
          BLACKLIST_INPUT_MODE="json"
          BLACKLIST_JSON_INPUT="$2"
          shift 2
        else
          BLACKLIST_INPUT_MODE="legacy"
          shift
        fi
        ;;
      --blacklist-host-drivers)
        [[ "${BLACKLIST_INPUT_MODE}" == none ]] || gpu.die "${GPU_EXIT_USAGE}" "conflicting blacklist selectors"
        BLACKLIST_HOST_DRIVERS=1
        BLACKLIST_INPUT_MODE="legacy"
        shift
        ;;
      --blacklist-all)
        BLACKLIST_HOST_DRIVERS=1
        [[ "${BLACKLIST_INPUT_MODE}" == none ]] || gpu.die "${GPU_EXIT_USAGE}" "conflicting blacklist selectors"
        BLACKLIST_INPUT_MODE="all"
        shift
        ;;
      --blacklist-amd|--blacklist-nvidia)
        BLACKLIST_HOST_DRIVERS=1
        [[ "${BLACKLIST_INPUT_MODE}" == none ]] || gpu.die "${GPU_EXIT_USAGE}" "conflicting blacklist selectors"
        BLACKLIST_INPUT_MODE="vendor"
        BLACKLIST_VENDOR_INPUT="${1#--blacklist-}"
        shift
        ;;
      --blacklist-vendor)
        gpu.require_value "$1" "${2-}"
        BLACKLIST_HOST_DRIVERS=1
        [[ "${BLACKLIST_INPUT_MODE}" == none ]] || gpu.die "${GPU_EXIT_USAGE}" "conflicting blacklist selectors"
        BLACKLIST_INPUT_MODE="vendor"
        BLACKLIST_VENDOR_INPUT="${2,,}"
        shift 2
        ;;
      --blacklist-gpu)
        gpu.require_value "$1" "${2-}"
        BLACKLIST_GPU_INPUTS+=("$2")
        shift 2
        ;;
      --allow-host-display-loss) ALLOW_HOST_DISPLAY_LOSS=1; shift ;;
      --allow-guest-console-loss) ALLOW_GUEST_CONSOLE_LOSS=1; shift ;;
      --primary-gpu) PRIMARY_GPU=1; shift ;;
      --disable-onboot) DISABLE_ONBOOT=1; shift ;;
      --iommu-pt) IOMMU_PT=1; shift ;;
      -h|--help|help) gpu.usage; exit 0 ;;
      *) gpu.die "${GPU_EXIT_USAGE}" "unknown argument: $1" ;;
    esac
  done

  case "${ACTION}" in
    inventory|preflight|prepare|verify|attach|detach|status|unprepare) ;;
    test) ACTION="verify" ;;
    *) gpu.die "${GPU_EXIT_USAGE}" "unsupported action: ${ACTION}" ;;
  esac
  case "${PROFILE}" in
    macos) PROFILE="macos-desktop" ;;
    winos|windows) PROFILE="windows-desktop" ;;
    linux|linuxOS) PROFILE="linux-desktop" ;;
    compute) PROFILE="linux-compute" ;;
  esac
  case "${PROFILE}" in
    macos-desktop|windows-desktop|linux-desktop|linux-compute) ;;
    *) gpu.die "${GPU_EXIT_USAGE}" "unsupported profile: ${PROFILE}" ;;
  esac
  case "${OUTPUT}" in human|json) ;; *) gpu.die "${GPU_EXIT_USAGE}" "--output must be human or json" ;; esac
  case "${REQUESTED_RELEASE}" in ""|auto|6.4|9.1) ;; *) gpu.die "${GPU_EXIT_USAGE}" "--release assertion must be 6.4 or 9.1" ;; esac
  case "${BINDING_REQUESTED}" in release|automatic|early) ;; *) gpu.die "${GPU_EXIT_USAGE}" "--binding must be release, automatic, or early" ;; esac
  [[ -z "${VM_ID}" || "${VM_ID}" =~ ^[1-9][0-9]*$ ]] || gpu.die "${GPU_EXIT_USAGE}" "invalid VM ID: ${VM_ID}"
  [[ "${HOSTPCI_INDEX}" == auto || "${HOSTPCI_INDEX}" =~ ^([0-9]|1[0-5])$ ]] || gpu.die "${GPU_EXIT_USAGE}" "--hostpci-index must be auto or 0..15"

  ((BLACKLIST_HOST_DRIVERS == 0)) || [[ "${ACTION}" == prepare ]] || gpu.die "${GPU_EXIT_USAGE}" "--blacklist is valid only with prepare"
  if ((BLACKLIST_HOST_DRIVERS == 1)); then
    [[ "${BINDING_REQUESTED}" == early ]] || gpu.die "${GPU_EXIT_USAGE}" "blacklist selection requires --binding early"
    case "${BLACKLIST_VENDOR_INPUT}" in ""|amd|nvidia) ;; *) gpu.die "${GPU_EXIT_USAGE}" "--blacklist-vendor must be amd or nvidia" ;; esac
    if [[ "${BLACKLIST_INPUT_MODE}" != legacy && -n "${GPU_INPUT}" ]]; then
      gpu.die "${GPU_EXIT_USAGE}" "--gpu cannot be combined with a multi-GPU blacklist selector"
    fi
  fi
  ((${#BLACKLIST_GPU_INPUTS[@]} == 0)) || [[ "${BLACKLIST_INPUT_MODE}" == vendor ]] \
    || gpu.die "${GPU_EXIT_USAGE}" "--blacklist-gpu requires --blacklist-vendor"
  ((PRIMARY_GPU == 0)) || [[ "${ACTION}" == attach || "${ACTION}" == preflight || "${ACTION}" == verify ]] || gpu.die "${GPU_EXIT_USAGE}" "--primary-gpu is valid only for preflight, verify, or attach"
  ((START_VM == 0)) || [[ "${ACTION}" == attach ]] || gpu.die "${GPU_EXIT_USAGE}" "--start is valid only with attach"
  ((REBOOT_HOST == 0)) || [[ "${ACTION}" == prepare || "${ACTION}" == unprepare ]] || gpu.die "${GPU_EXIT_USAGE}" "--reboot is valid only with prepare or unprepare"
  if ((PRIMARY_GPU == 1)) && [[ "${PROFILE}" == linux-compute ]]; then
    gpu.die "${GPU_EXIT_USAGE}" "--primary-gpu conflicts with the linux-compute profile"
  fi
  if ((PRIMARY_GPU == 1)) && ((ALLOW_GUEST_CONSOLE_LOSS == 0 || YES == 0)) && ((DRY_RUN == 0)); then
    gpu.die "${GPU_EXIT_PREFLIGHT}" "--primary-gpu requires --allow-guest-console-loss --yes"
  fi
  if ((RESET_ALIAS_USED == 1)); then
    gpu.warn "--reset is deprecated; use --reboot"
  fi
}

gpu.require_root() {
  [[ "${TEST_MODE}" == 1 || "${EUID}" -eq 0 ]] || gpu.die "${GPU_EXIT_ENVIRONMENT}" "run this action as root on the Proxmox node"
}

gpu.require_commands() {
  local command_name=""
  shift 0
  for command_name in "$@"; do
    gpu.command_exists "${command_name}" || gpu.die "${GPU_EXIT_DEPENDENCY}" "missing required command: ${command_name}"
  done
}

gpu.sysfs_value() {
  local bdf="$1" name="$2" fallback="${3:-}"
  local path="${SYSFS_ROOT}/bus/pci/devices/${bdf}/${name}"
  if [[ -r "${path}" ]]; then tr -d '\n' < "${path}"; else printf '%s\n' "${fallback}"; fi
}

gpu.device_driver() {
  local link="${SYSFS_ROOT}/bus/pci/devices/$1/driver"
  if [[ -L "${link}" ]]; then basename "$(readlink "${link}")"; else printf 'unbound\n'; fi
}

gpu.device_group() {
  local link="${SYSFS_ROOT}/bus/pci/devices/$1/iommu_group"
  [[ -L "${link}" ]] || return 1
  basename "$(readlink "${link}")"
}

gpu.state_value() {
  local key="$1" file="$2"
  [[ -r "${file}" ]] || return 1
  if gpu.state_is_json "${file}"; then
    jq -r --arg key "${key}" '.[$key] // empty' "${file}" 2>/dev/null
  else
    sed -n "s/^${key}=//p" "${file}" | head -n1
  fi
}

gpu.state_is_json() {
  local file="$1" first=""
  [[ -r "${file}" ]] || return 1
  first="$(sed -n '/[^[:space:]]/ { s/[[:space:]]//g; p; }' "${file}" | head -n1)"
  [[ "${first}" == \{* ]]
}

gpu.is_mutating_action() {
  case "$1" in prepare|attach|detach|unprepare) return 0 ;; *) return 1 ;; esac
}

GPU_LIBRARY_DIR="${PROXMOX_GPU_CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/gpu"
[[ -r "${GPU_LIBRARY_DIR}/platform.sh" ]] || gpu.die "${GPU_EXIT_DEPENDENCY}" \
  "missing GPU platform helper: ${GPU_LIBRARY_DIR}/platform.sh"
[[ -r "${GPU_LIBRARY_DIR}/inventory.sh" ]] || gpu.die "${GPU_EXIT_DEPENDENCY}" \
  "missing GPU inventory helper: ${GPU_LIBRARY_DIR}/inventory.sh"
# shellcheck source=cli/gpu/platform.sh
source "${GPU_LIBRARY_DIR}/platform.sh"
# shellcheck source=cli/gpu/inventory.sh
source "${GPU_LIBRARY_DIR}/inventory.sh"
