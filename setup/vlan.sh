#!/usr/bin/env bash
## Discovery-led Proxmox data-bridge feature runner (untagged or VLAN-aware).
## Local usage:
##   ./setup/vlan.sh [preflight|probe|write|apply]
## Published usage:
##   wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash

set -euo pipefail

log()       { printf '[setup.vlan] %s\n' "$*" >&2; }
log.warn()  { printf '[setup.vlan][warn] %s\n' "$*" >&2; }
log.error() { printf '[setup.vlan][error] %s\n' "$*" >&2; }

TMP_DIR="/tmp/pve-feature-vlan"
PAGES_BASE_URL="https://devs-guide.github.io/proxmox"
PLAYBOOK_ROOT="${TMP_DIR}/ansible"
PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
LOCAL_COMMON_HELPER="../bootstrap/release.common.sh"
COMMON_HELPER_NAME="release.common.sh"
COMMON_HELPER_URL="${PAGES_BASE_URL}/${COMMON_HELPER_NAME}"
COMMON_HELPER_PATH="${TMP_DIR}/${COMMON_HELPER_NAME}"
GROUP_VARS_FILE="proxmox.yml"
GROUP_VARS_URL="${PAGES_BASE_URL}/ansible/group_vars/${GROUP_VARS_FILE}"
GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
FEATURE_PLAYBOOKS=(
  "proxmox/helper/hardware.yml"
  "proxmox/vlan.yml"
)
FEATURE_SUPPORT_FILES=(
  "proxmox/tasks/data-link.candidate.yml"
  "proxmox/templates/data-link.interfaces.j2"
)
HARDWARE_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[0]}"
VLAN_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[1]}"
VLAN_TASKS_REL="${FEATURE_SUPPORT_FILES[0]}"
VLAN_TEMPLATE_REL="${FEATURE_SUPPORT_FILES[1]}"
HARDWARE_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${HARDWARE_PLAYBOOK_REL}"
HARDWARE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${HARDWARE_PLAYBOOK_REL}"
VLAN_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${VLAN_PLAYBOOK_REL}"
VLAN_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${VLAN_PLAYBOOK_REL}"
VLAN_TASKS_URL="${PAGES_BASE_URL}/ansible/${VLAN_TASKS_REL}"
VLAN_TASKS_PATH="${PLAYBOOK_ROOT}/${VLAN_TASKS_REL}"
VLAN_TEMPLATE_URL="${PAGES_BASE_URL}/ansible/${VLAN_TEMPLATE_REL}"
VLAN_TEMPLATE_PATH="${PLAYBOOK_ROOT}/${VLAN_TEMPLATE_REL}"
NETWORK_LINK_RUNNER_URL="${PAGES_BASE_URL}/setup/network-link.sh"
NETWORK_LINK_RUNNER_PATH="${TMP_DIR}/network-link.sh"
VLAN_EXTRA_VARS_PATH="${TMP_DIR}/vlan.extra-vars.yml"
ANSIBLE_VENV="/opt/ansible-venv"
ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
ANSIBLE_CORE_VERSION="2.20.5"
ANSIBLE_CORE_SPEC="ansible-core==${ANSIBLE_CORE_VERSION}"
PROXMOX_RUNTIME_CONTEXT="host"
FEATURE_MODE_ARGUMENT="${1:-}"
FEATURE_MODE="${FEATURE_MODE_ARGUMENT:-${PROXMOX_VLAN_MODE:-preflight}}"
FEATURE_MODE_EXPLICIT=0
[[ -n "${FEATURE_MODE_ARGUMENT}" ]] && FEATURE_MODE_EXPLICIT=1
FEATURE_USE_DISCOVERY="${PROXMOX_VLAN_USE_DISCOVERY:-true}"
FEATURE_OOB_ACK="${PROXMOX_VLAN_CONFIRM_OOB:-}"
FEATURE_INTERACTIVE="${PROXMOX_VLAN_INTERACTIVE:-1}"
FACTS_DIR="${PROXMOX_VLAN_FACTS_DIR:-/etc/ansible/proxmox/facts}"
INTERFACES_PATH="${PROXMOX_VLAN_INTERFACES_PATH:-/etc/network/interfaces}"
HARDWARE_FACTS_PATH="${PROXMOX_VLAN_HARDWARE_FACTS_PATH:-${FACTS_DIR}/hardware.yml}"
HARDWARE_NICS_TSV="${PROXMOX_VLAN_HARDWARE_NICS_TSV:-${FACTS_DIR}/hardware.nics.tsv}"
VLAN_PENDING_SELECTION_PATH="${PROXMOX_VLAN_PENDING_SELECTION_PATH:-${FACTS_DIR}/vlan.pending.yml}"
VLAN_APPLIED_SELECTION_PATH="${PROXMOX_VLAN_APPLIED_SELECTION_PATH:-${FACTS_DIR}/vlan.applied.yml}"
VLAN_COMPAT_SELECTION_PATH="${PROXMOX_VLAN_COMPAT_SELECTION_PATH:-${FACTS_DIR}/vlan.selection.yml}"
VLAN_SELECTION_PATH="${PROXMOX_VLAN_SELECTION_PATH:-${VLAN_PENDING_SELECTION_PATH}}"
NETWORK_LINK_SELECTION_PATH="${PROXMOX_NETWORK_LINK_SELECTION_PATH:-${FACTS_DIR}/network-link.selection.yml}"
NETWORK_LINK_READY_PATH="${PROXMOX_NETWORK_LINK_READY_PATH:-${FACTS_DIR}/network-link.ready.yml}"
DEFAULT_DATA_BRIDGE="${PROXMOX_VLAN_DATA_BRIDGE:-}"
DEFAULT_LINK_MODE="${PROXMOX_VLAN_LINK_MODE:-untagged}"
DEFAULT_BRIDGE_VIDS="${PROXMOX_VLAN_BRIDGE_VIDS:-}"
PROBE_SECONDS="${PROXMOX_VLAN_PROBE_SECONDS:-3}"
ALLOW_VLAN_1="${PROXMOX_VLAN_ALLOW_VLAN_1:-false}"
ALLOW_ALL_VLAN_RANGE="${PROXMOX_VLAN_ALLOW_ALL_VLAN_RANGE:-false}"
ALLOW_SAME_MANAGEMENT_AND_DATA_NIC="${PROXMOX_VLAN_ALLOW_SAME_MANAGEMENT_AND_DATA_NIC:-false}"
ALLOW_DATA_NIC_WITH_HOST_IP="${PROXMOX_VLAN_ALLOW_DATA_NIC_WITH_HOST_IP:-false}"
ALLOW_DATA_NIC_BRIDGE_MEMBER="${PROXMOX_VLAN_ALLOW_DATA_NIC_BRIDGE_MEMBER:-false}"
MIN_DATA_SPEED_MBPS="${PROXMOX_VLAN_MIN_DATA_SPEED_MBPS:-1000}"

declare -a NIC_IFACE=()
declare -a NIC_ROLE=()
declare -a NIC_SCORE=()
declare -a NIC_SPEED=()
declare -a NIC_SUPPORTED_SPEED=()
declare -a NIC_DRIVER=()
declare -a NIC_PCI=()
declare -a NIC_PCI_LABEL=()
declare -a NIC_MAC=()
declare -a NIC_PERMANENT_MAC=()
declare -a NIC_IP=()
declare -a NIC_BRIDGE_MEMBER=()
declare -a NIC_OPERSTATE=()
declare -a NIC_CARRIER=()
declare -a NIC_REASON=()

MGMT_BRIDGE=""
MGMT_NIC=""
MGMT_IP_CIDR=""
MGMT_GATEWAY=""
MGMT_GUI_PORT="8006"
SELECTED_DATA_NIC=""
SELECTED_DATA_BRIDGE=""
SELECTED_DATA_LINK_MODE=""
SELECTED_DATA_BRIDGE_VIDS=""
SELECTED_DATA_DRIVER=""
SELECTED_DATA_PCI=""
SELECTED_DATA_MAC=""
SELECTED_DATA_HOST_IP="null"
SELECTION_OOB_ACK="false"
PERSISTED_SELECTION_FOUND=0
PERSISTED_SELECTION_REUSABLE=0
PERSISTED_SELECTION_REUSED=0
PERSISTED_SELECTION_REASON="not evaluated"
PERSISTED_DATA_NIC=""
PERSISTED_DATA_BRIDGE=""
PERSISTED_DATA_LINK_MODE=""
PERSISTED_DATA_BRIDGE_VIDS=""
PERSISTED_DATA_DRIVER=""
PERSISTED_DATA_PCI=""
PERSISTED_DATA_MAC=""
PERSISTED_FROM_MANAGED_BLOCK=0

source.release.common() {
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  if [[ -n "${script_dir}" && -r "${script_dir}/${LOCAL_COMMON_HELPER}" ]]; then
    # shellcheck source=bootstrap/release.common.sh
    source "${script_dir}/${LOCAL_COMMON_HELPER}"
    return
  fi

  mkdir -p "${TMP_DIR}"
  log "Fetching shared bootstrap helper: ${COMMON_HELPER_URL}"
  if ! wget -qO "${COMMON_HELPER_PATH}" "${COMMON_HELPER_URL}"; then
    log.error "Failed to fetch shared bootstrap helper: ${COMMON_HELPER_URL}"
    exit 1
  fi
  if [[ ! -s "${COMMON_HELPER_PATH}" ]]; then
    log.error "Shared bootstrap helper is empty: ${COMMON_HELPER_URL}"
    exit 1
  fi
  # shellcheck source=/tmp/pve-feature-vlan/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

source.release.common

is.true() {
  local value="${1:-}"
  case "${value,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

require.proxmox() {
  if command -v pveversion >/dev/null 2>&1; then
    return
  fi
  log.error "This feature runner expects a Proxmox host."
  exit 1
}

require.valid.mode() {
  case "${FEATURE_MODE}" in
    preflight|probe|write|apply) ;;
    *)
      log.error "Unsupported mode: ${FEATURE_MODE}"
      log.error "Use one of: preflight, probe, write, apply"
      exit 1
      ;;
  esac
}

require.host.network.ready() {
  if [[ ! -f "${INTERFACES_PATH}" ]]; then
    log.error "Interfaces file is missing: ${INTERFACES_PATH}"
    exit 1
  fi
}

require.oob.ack() {
  if [[ "${FEATURE_MODE}" == "preflight" || "${FEATURE_MODE}" == "probe" ]]; then
    return
  fi

  if [[ "${FEATURE_OOB_ACK}" != "YES" ]]; then
    log.error "write/apply modes require an out-of-band console confirmation."
    log.error "Re-run with PROXMOX_VLAN_CONFIRM_OOB=YES after confirming console access."
    exit 1
  fi
}

open.tty() {
  if [[ ! -r /dev/tty ]]; then
    return 1
  fi
  exec 3<>/dev/tty
  return 0
}

prompt.tty() {
  local prompt="$1"
  local default="${2:-}"
  local answer=""

  if [[ -n "${default}" ]]; then
    printf '%s [%s]: ' "${prompt}" "${default}" >&3
  else
    printf '%s: ' "${prompt}" >&3
  fi
  read -r -u 3 answer || true
  if [[ -z "${answer}" ]]; then
    answer="${default}"
  fi
  printf '%s\n' "${answer}"
}

menu.tty() {
  local prompt="$1"
  shift
  local -a options=("$@")
  local answer=""
  local i

  while true; do
    printf '%s\n' "${prompt}" >&3
    for i in "${!options[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${options[$i]}" >&3
    done
    printf 'Select option: ' >&3
    read -r -u 3 answer || true
    if [[ "${answer}" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#options[@]})); then
      printf '%s\n' "${answer}"
      return 0
    fi
    printf 'Invalid selection.\n' >&3
  done
}

yaml.quote() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

yaml.scalar.or.null() {
  local value="${1:-}"
  if [[ -z "${value}" || "${value}" == "-" ]]; then
    printf 'null'
  else
    yaml.quote "${value}"
  fi
}

bool.yaml() {
  if is.true "${1:-false}"; then
    printf 'true'
  else
    printf 'false'
  fi
}

nic.speed.class() {
  local driver="${1:-}"
  local speed="${2:-}"
  local supported_speed="${3:-}"

  if [[ "${speed}" =~ ^[0-9]+$ ]] && (( speed >= 10000 )); then
      printf '%sMbps linked' "${speed}"
      return
  fi
  if [[ "${supported_speed}" =~ ^[0-9]+$ ]]; then
    if (( supported_speed >= 1000 )); then
      printf '%sMbps capable' "${supported_speed}"
      return
    fi
  fi

  case "${driver}" in
    ixgbe|i40e|ice|mlx5_core|bnxt_en|atlantic)
      printf 'multi-gigabit capable'
      ;;
    igb|e1000e|igc|tg3|r8169|r8152|r8153_ecm)
      printf 'gigabit capable'
      ;;
    *)
      printf 'unknown-class'
      ;;
  esac
}

nic.speed.evidence.mbps() {
  local driver="${1:-}" speed="${2:-}" supported_speed="${3:-}" evidence=0
  if [[ "${speed}" =~ ^[0-9]+$ ]] && ((speed > evidence)); then
    evidence="${speed}"
  fi
  if [[ "${supported_speed}" =~ ^[0-9]+$ ]] && ((supported_speed > evidence)); then
    evidence="${supported_speed}"
  fi
  case "${driver}" in
    ixgbe|i40e|ice|mlx5_core|bnxt_en|atlantic)
      ((evidence >= 10000)) || evidence=10000
      ;;
    igb|e1000e|igc|tg3|r8169|r8152|r8153_ecm)
      ((evidence >= 1000)) || evidence=1000
      ;;
  esac
  printf '%s\n' "${evidence}"
}

nic.meets.minimum.speed() {
  local evidence
  evidence="$(nic.speed.evidence.mbps "${1:-}" "${2:-}" "${3:-}")"
  [[ "${MIN_DATA_SPEED_MBPS}" =~ ^[0-9]+$ ]] || return 1
  ((evidence >= MIN_DATA_SPEED_MBPS))
}

nic.recommendation.label() {
  local role="${1:-}"
  local score="${2:-0}"
  local driver="${3:-}"

  if [[ "${role}" == "data_candidate" ]]; then
    case "${driver}" in
      ixgbe|i40e|ice|mlx5_core|bnxt_en|atlantic)
        printf 'RECOMMENDED'
        return
        ;;
    esac
    if [[ "${score}" =~ ^[0-9]+$ ]] && (( score >= 60 )); then
      printf 'fallback'
      return
    fi
  fi

  printf 'not-selectable'
}

build.management.snapshot() {
  local default_route_device master_path port
  default_route_device="$(ip route show default | awk 'NR==1 {print $5}')"
  MGMT_GATEWAY="$(ip route show default | awk 'NR==1 {print $3}')"

  if [[ -d "/sys/class/net/${default_route_device}/bridge" ]]; then
    MGMT_BRIDGE="${default_route_device}"
  elif [[ -L "/sys/class/net/${default_route_device}/master" ]]; then
    master_path="$(readlink -f "/sys/class/net/${default_route_device}/master")"
    MGMT_BRIDGE="$(basename "${master_path}")"
  elif [[ -n "${default_route_device}" ]]; then
    MGMT_BRIDGE="${default_route_device}"
  fi

  MGMT_NIC=""
  if [[ -d "/sys/class/net/${MGMT_BRIDGE}/brif" ]]; then
    for port in /sys/class/net/"${MGMT_BRIDGE}"/brif/*; do
      [[ -e "${port}" ]] || continue
      if [[ -e "/sys/class/net/$(basename "${port}")/device" ]]; then
        MGMT_NIC="$(basename "${port}")"
        break
      fi
    done
  fi
  if [[ -z "${MGMT_NIC}" && -e "/sys/class/net/${default_route_device}/device" ]]; then
    MGMT_NIC="${default_route_device}"
  fi

  MGMT_IP_CIDR="$(ip -o -4 addr show dev "${MGMT_BRIDGE}" 2>/dev/null | awk 'NR==1 {print $4}')"
  if [[ -z "${MGMT_IP_CIDR}" && -n "${MGMT_NIC}" ]]; then
    MGMT_IP_CIDR="$(ip -o -4 addr show dev "${MGMT_NIC}" 2>/dev/null | awk 'NR==1 {print $4}')"
  fi
}

suggest.data.bridge() {
  local bridge_number=1 candidate=""
  while ((bridge_number < 4096)); do
    candidate="vmbr${bridge_number}"
    if [[ ! -e "/sys/class/net/${candidate}" ]] \
      && ! grep -qE "^[[:space:]]*(auto|iface)[[:space:]]+${candidate}([[:space:]]|$)" "${INTERFACES_PATH}" 2>/dev/null; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    bridge_number=$((bridge_number + 1))
  done
  return 1
}

load.management.from.hardware.facts() {
  local py=""
  local parsed=""

  [[ -f "${HARDWARE_FACTS_PATH}" ]] || return 0
  py="$(select.yaml.python || true)"
  [[ -n "${py}" ]] || return 0

  parsed="$("${py}" - <<PY
import yaml
from pathlib import Path

p = Path("${HARDWARE_FACTS_PATH}")
data = yaml.safe_load(p.read_text()) or {}
mgmt = (data.get("proxmox_hardware_discovered") or {}).get("management") or {}

print(mgmt.get("bridge") or "")
print(mgmt.get("nic") or "")
print(mgmt.get("ip_cidr") or "")
print(mgmt.get("gateway") or "")
print(mgmt.get("gui_port") or "8006")
PY
)" || return 0

  MGMT_BRIDGE="$(printf '%s\n' "${parsed}" | sed -n '1p')"
  MGMT_NIC="$(printf '%s\n' "${parsed}" | sed -n '2p')"
  MGMT_IP_CIDR="$(printf '%s\n' "${parsed}" | sed -n '3p')"
  MGMT_GATEWAY="$(printf '%s\n' "${parsed}" | sed -n '4p')"
  MGMT_GUI_PORT="$(printf '%s\n' "${parsed}" | sed -n '5p')"
}

select.yaml.python() {
  local candidate=""
  local -a candidates=(
    "${ANSIBLE_VENV}/bin/python"
    "${MANAGED_TARGET_PYTHON_PATH}"
    "${PYTHON_BOOTSTRAP_BIN:-}"
    "python3"
  )

  for candidate in "${candidates[@]}"; do
    [[ -n "${candidate}" ]] || continue
    if [[ ! -x "${candidate}" ]] && ! command -v "${candidate}" >/dev/null 2>&1; then
      continue
    fi
    if "${candidate}" - <<'PY' >/dev/null 2>&1
import yaml
PY
    then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

load.selection.from.path() {
  local selection_path="$1" py="" parsed="" confirmed=""
  [[ -f "${selection_path}" ]] || return 1
  py="$(select.yaml.python || true)"
  [[ -n "${py}" ]] || return 1

  parsed="$("${py}" - "${selection_path}" <<'PY'
import sys
from pathlib import Path
import yaml

payload = yaml.safe_load(Path(sys.argv[1]).read_text()) or {}
selection = payload.get("proxmox_vlan_operator_selection") or {}
data = selection.get("data") or {}

print("true" if selection.get("confirmed") is True else "false")
for key in ("nic", "bridge", "link_mode", "bridge_vids", "expected_driver", "expected_pci", "expected_mac"):
    print(data.get(key) or "")
PY
)" || return 1

  confirmed="$(printf '%s\n' "${parsed}" | sed -n '1p')"
  [[ "${confirmed}" == "true" ]] || return 1
  PERSISTED_DATA_NIC="$(printf '%s\n' "${parsed}" | sed -n '2p')"
  PERSISTED_DATA_BRIDGE="$(printf '%s\n' "${parsed}" | sed -n '3p')"
  PERSISTED_DATA_LINK_MODE="$(printf '%s\n' "${parsed}" | sed -n '4p')"
  PERSISTED_DATA_BRIDGE_VIDS="$(printf '%s\n' "${parsed}" | sed -n '5p')"
  PERSISTED_DATA_DRIVER="$(printf '%s\n' "${parsed}" | sed -n '6p')"
  PERSISTED_DATA_PCI="$(printf '%s\n' "${parsed}" | sed -n '7p')"
  PERSISTED_DATA_MAC="$(printf '%s\n' "${parsed}" | sed -n '8p')"
  [[ -n "${PERSISTED_DATA_NIC}" && -n "${PERSISTED_DATA_BRIDGE}" ]] || return 1
  PERSISTED_SELECTION_FOUND=1
}

load.managed.block.selection() {
  local parsed="" bridge="" nic="" link_mode="untagged" bridge_vids="" selected_index=""
  [[ -r "${INTERFACES_PATH}" ]] || return 1
  parsed="$(awk '
    /^# BEGIN ANSIBLE MANAGED BLOCK: (ansible-proxmox-vlan-vmbr1|[d]evsguide-proxmox-vlan-vmbr1|ansible-proxmox-data-bridge)$/ {inside=1; next}
    /^# END ANSIBLE MANAGED BLOCK: (ansible-proxmox-vlan-vmbr1|[d]evsguide-proxmox-vlan-vmbr1|ansible-proxmox-data-bridge)$/ {inside=0; next}
    inside && $1 == "auto" && bridge == "" {bridge=$2}
    inside && /bridge-ports[[:space:]]+/ && nic == "" {
      for (i=1; i<=NF; i++) if ($i == "bridge-ports") {nic=$(i+1); break}
    }
    inside && $1 == "bridge-vlan-aware" && $2 == "yes" {mode="vlan-aware"}
    inside && $1 == "bridge-vids" {$1=""; sub(/^[[:space:]]+/, ""); vids=$0}
    END {if (bridge != "" && nic != "") printf "%s\n%s\n%s\n%s\n", bridge, nic, (mode == "" ? "untagged" : mode), vids}
  ' "${INTERFACES_PATH}")"
  bridge="$(printf '%s\n' "${parsed}" | sed -n '1p')"
  nic="$(printf '%s\n' "${parsed}" | sed -n '2p')"
  link_mode="$(printf '%s\n' "${parsed}" | sed -n '3p')"
  bridge_vids="$(printf '%s\n' "${parsed}" | sed -n '4p')"
  [[ -n "${bridge}" && -n "${nic}" ]] || return 1
  selected_index="$(lookup.nic.index "${nic}" || true)"
  [[ -n "${selected_index}" ]] || return 1
  PERSISTED_DATA_BRIDGE="${bridge}"
  PERSISTED_DATA_NIC="${nic}"
  PERSISTED_DATA_LINK_MODE="${link_mode:-untagged}"
  PERSISTED_DATA_BRIDGE_VIDS="${bridge_vids}"
  PERSISTED_DATA_DRIVER="${NIC_DRIVER[$selected_index]}"
  PERSISTED_DATA_PCI="${NIC_PCI[$selected_index]}"
  PERSISTED_DATA_MAC="${NIC_PERMANENT_MAC[$selected_index]}"
  [[ -n "${PERSISTED_DATA_MAC}" && "${PERSISTED_DATA_MAC}" != "-" ]] || PERSISTED_DATA_MAC="${NIC_MAC[$selected_index]}"
  PERSISTED_SELECTION_FOUND=1
  PERSISTED_FROM_MANAGED_BLOCK=1
}

load.persisted.selection() {
  load.managed.block.selection && return 0
  load.selection.from.path "${VLAN_APPLIED_SELECTION_PATH}" && return 0
  load.selection.from.path "${VLAN_PENDING_SELECTION_PATH}" && return 0
  load.selection.from.path "${VLAN_COMPAT_SELECTION_PATH}"
}

persisted.selection.has.managed.config() {
  local interfaces_path="${INTERFACES_PATH}"
  [[ -r "${interfaces_path}" ]] || return 1
  grep -Eq '^# BEGIN ANSIBLE MANAGED BLOCK: (ansible-proxmox-vlan-vmbr1|[d]evsguide-proxmox-vlan-vmbr1|ansible-proxmox-data-bridge)$' "${interfaces_path}" || return 1
  grep -Eq "^[[:space:]]*iface[[:space:]]+${PERSISTED_DATA_BRIDGE}[[:space:]]+inet[[:space:]]+(manual|static)([[:space:]]|$)" "${interfaces_path}" || return 1
  grep -Eq "bridge-ports[[:space:]]+${PERSISTED_DATA_NIC}([[:space:]]|$)" "${interfaces_path}"
}

assess.persisted.selection() {
  local selected_index="" selected_ip="" selected_member="" speed_evidence="" bridge_ipv4=""
  PERSISTED_SELECTION_REUSABLE=0
  PERSISTED_SELECTION_REASON="persisted selection is incomplete"
  ((PERSISTED_SELECTION_FOUND == 1)) || return 1

  selected_index="$(lookup.nic.index "${PERSISTED_DATA_NIC}" || true)"
  if [[ -z "${selected_index}" ]]; then
    PERSISTED_SELECTION_REASON="selected physical NIC is no longer present"
    return 1
  fi
  if [[ "${PERSISTED_DATA_BRIDGE}" == "${MGMT_BRIDGE}" ]]; then
    PERSISTED_SELECTION_REASON="selected data bridge now matches the management bridge"
    return 1
  fi
  selected_ip="${NIC_IP[$selected_index]}"
  selected_member="${NIC_BRIDGE_MEMBER[$selected_index]}"
  speed_evidence="$(nic.speed.evidence.mbps "${NIC_DRIVER[$selected_index]}" "${NIC_SPEED[$selected_index]}" "${NIC_SUPPORTED_SPEED[$selected_index]}")"
  if [[ "${selected_ip}" != "-" ]]; then
    PERSISTED_SELECTION_REASON="selected physical NIC now has host IP ${selected_ip}"
    return 1
  fi
  if [[ ! "${speed_evidence}" =~ ^[0-9]+$ ]] || ((speed_evidence < MIN_DATA_SPEED_MBPS)); then
    PERSISTED_SELECTION_REASON="selected physical NIC no longer satisfies ${MIN_DATA_SPEED_MBPS}Mbps policy"
    return 1
  fi
  if [[ "${selected_member}" == "${PERSISTED_DATA_BRIDGE}" ]]; then
    if [[ ! -d "/sys/class/net/${PERSISTED_DATA_BRIDGE}/bridge" ]]; then
      PERSISTED_SELECTION_REASON="selected member target is not a Linux bridge"
      return 1
    fi
    bridge_ipv4="$(ip -o -4 addr show dev "${PERSISTED_DATA_BRIDGE}" 2>/dev/null | awk 'NR==1 {print $4}')"
    if [[ -n "${bridge_ipv4}" ]]; then
      PERSISTED_SELECTION_REASON="managed data bridge unexpectedly has host IPv4 ${bridge_ipv4}"
      return 1
    fi
    if ip route show default dev "${PERSISTED_DATA_BRIDGE}" 2>/dev/null | grep -q '^default '; then
      PERSISTED_SELECTION_REASON="managed data bridge unexpectedly owns a default route"
      return 1
    fi
  elif [[ "${selected_member}" == "-" ]]; then
    if ! persisted.selection.has.managed.config; then
      PERSISTED_SELECTION_REASON="selection is not live and no matching managed config block exists"
      return 1
    fi
    if ip link show dev "${PERSISTED_DATA_BRIDGE}" >/dev/null 2>&1 \
      && [[ ! -d "/sys/class/net/${PERSISTED_DATA_BRIDGE}/bridge" ]]; then
      PERSISTED_SELECTION_REASON="selected bridge name belongs to a non-bridge interface"
      return 1
    fi
    if ((PERSISTED_FROM_MANAGED_BLOCK == 1)); then
      PERSISTED_SELECTION_REUSABLE=1
      PERSISTED_SELECTION_REASON="feature-owned bridge selection is staged and will be canonicalized"
      return 0
    fi
  else
    PERSISTED_SELECTION_REASON="selected NIC is attached to foreign bridge ${selected_member}"
    return 1
  fi

  PERSISTED_SELECTION_REUSABLE=1
  PERSISTED_SELECTION_REASON="managed selection matches live or staged topology"
}

selected.bridge.member.allowed() {
  local member="${1:-}"
  [[ -z "${member}" || "${member}" == "-" ]] && return 0
  if ((PERSISTED_SELECTION_REUSED == 1)) && [[ "${member}" == "${SELECTED_DATA_BRIDGE}" ]]; then
    return 0
  fi
  is.true "${ALLOW_DATA_NIC_BRIDGE_MEMBER}"
}

apply.persisted.selection() {
  local selected_index=""
  selected_index="$(lookup.nic.index "${PERSISTED_DATA_NIC}" || true)"
  [[ -n "${selected_index}" ]] || return 1
  SELECTED_DATA_NIC="${PERSISTED_DATA_NIC}"
  SELECTED_DATA_BRIDGE="${PERSISTED_DATA_BRIDGE}"
  SELECTED_DATA_LINK_MODE="${PERSISTED_DATA_LINK_MODE:-untagged}"
  SELECTED_DATA_BRIDGE_VIDS="${PERSISTED_DATA_BRIDGE_VIDS}"
  SELECTED_DATA_DRIVER="${PERSISTED_DATA_DRIVER:-${NIC_DRIVER[$selected_index]}}"
  SELECTED_DATA_PCI="${PERSISTED_DATA_PCI:-${NIC_PCI[$selected_index]}}"
  SELECTED_DATA_MAC="${PERSISTED_DATA_MAC:-${NIC_PERMANENT_MAC[$selected_index]}}"
  if [[ -z "${SELECTED_DATA_MAC}" || "${SELECTED_DATA_MAC}" == "-" ]]; then
    SELECTED_DATA_MAC="${NIC_MAC[$selected_index]}"
  fi
  PERSISTED_SELECTION_REUSED=1
}

load.nic.summary() {
  local row field_count
  local iface role score speed supported_speed driver pci pci_label mac permanent_mac ip_cidr bridge_member operstate carrier reason
  [[ -f "${HARDWARE_NICS_TSV}" ]] || {
    log.error "Missing NIC summary: ${HARDWARE_NICS_TSV}"
    exit 1
  }

  NIC_IFACE=()
  NIC_ROLE=()
  NIC_SCORE=()
  NIC_SPEED=()
  NIC_SUPPORTED_SPEED=()
  NIC_DRIVER=()
  NIC_PCI=()
  NIC_PCI_LABEL=()
  NIC_MAC=()
  NIC_PERMANENT_MAC=()
  NIC_IP=()
  NIC_BRIDGE_MEMBER=()
  NIC_OPERSTATE=()
  NIC_CARRIER=()
  NIC_REASON=()

  while IFS= read -r row || [[ -n "${row}" ]]; do
    [[ -n "${row}" ]] || continue

    row="${row%$'\r'}"
    [[ "${row}" == iface$'\t'* ]] && continue
    [[ "${row}" == 'iface\t'* ]] && continue

    row="${row//\\t/$'\t'}"
    field_count="$(awk -F $'\t' '{print NF; exit}' <<< "${row}")"

    iface=""
    role=""
    score=""
    speed=""
    supported_speed=""
    driver=""
    pci=""
    pci_label=""
    mac=""
    permanent_mac=""
    ip_cidr=""
    bridge_member=""
    operstate=""
    carrier=""
    reason=""

    if [[ "${field_count}" -ge 15 ]]; then
      IFS=$'\t' read -r iface role score speed supported_speed driver pci pci_label mac permanent_mac ip_cidr bridge_member operstate carrier reason <<< "${row}"
    elif [[ "${field_count}" -ge 13 ]]; then
      IFS=$'\t' read -r iface role score speed driver pci pci_label mac ip_cidr bridge_member operstate carrier reason <<< "${row}"
    else
      IFS=$'\t' read -r iface role score speed driver pci mac ip_cidr bridge_member operstate carrier reason <<< "${row}"
    fi

    [[ -n "${iface:-}" ]] || continue
    NIC_IFACE+=("${iface}")
    NIC_ROLE+=("${role:-other}")
    NIC_SCORE+=("${score:-0}")
    NIC_SPEED+=("${speed:-"-"}")
    NIC_SUPPORTED_SPEED+=("${supported_speed:-"-"}")
    NIC_DRIVER+=("${driver:-"-"}")
    NIC_PCI+=("${pci:-"-"}")
    NIC_PCI_LABEL+=("${pci_label:-"-"}")
    NIC_MAC+=("${mac:-"-"}")
    NIC_PERMANENT_MAC+=("${permanent_mac:-"-"}")
    NIC_IP+=("${ip_cidr:-"-"}")
    NIC_BRIDGE_MEMBER+=("${bridge_member:-"-"}")
    NIC_OPERSTATE+=("${operstate:-"-"}")
    NIC_CARRIER+=("${carrier:-"-"}")
    NIC_REASON+=("${reason:-"-"}")
  done < "${HARDWARE_NICS_TSV}"

  if ((${#NIC_IFACE[@]} == 0)); then
    log.error "No NIC rows found in ${HARDWARE_NICS_TSV}."
    exit 1
  fi
}

lookup.nic.index() {
  local target="$1"
  local i
  for i in "${!NIC_IFACE[@]}"; do
    if [[ "${NIC_IFACE[$i]}" == "${target}" ]]; then
      printf '%s\n' "${i}"
      return 0
    fi
  done
  return 1
}

resolve.selected.nic.identity() {
  local candidate_path candidate candidate_pci candidate_mac candidate_permanent matches resolved=""

  if [[ -z "${SELECTED_DATA_PCI}" || "${SELECTED_DATA_PCI}" == "-" ]] \
    && [[ -z "${SELECTED_DATA_MAC}" || "${SELECTED_DATA_MAC}" == "-" ]]; then
    [[ -e "/sys/class/net/${SELECTED_DATA_NIC}/device" ]] || {
      log.error "Selected physical NIC no longer exists: ${SELECTED_DATA_NIC}"
      exit 1
    }
    return 0
  fi

  for candidate_path in /sys/class/net/*; do
    [[ -e "${candidate_path}/device" ]] || continue
    candidate="$(basename "${candidate_path}")"
    candidate_pci="$(basename "$(readlink -f "${candidate_path}/device")")"
    candidate_mac="$(cat "${candidate_path}/address" 2>/dev/null || true)"
    candidate_permanent="$(ethtool -P "${candidate}" 2>/dev/null | awk '{print $3}' || true)"
    matches=1

    if [[ -n "${SELECTED_DATA_PCI}" && "${SELECTED_DATA_PCI}" != "-" && "${candidate_pci}" != "${SELECTED_DATA_PCI}" ]]; then
      matches=0
    fi
    if [[ -n "${SELECTED_DATA_MAC}" && "${SELECTED_DATA_MAC}" != "-" \
      && "${candidate_mac,,}" != "${SELECTED_DATA_MAC,,}" \
      && "${candidate_permanent,,}" != "${SELECTED_DATA_MAC,,}" ]]; then
      matches=0
    fi
    if ((matches == 1)); then
      if [[ -n "${resolved}" ]]; then
        log.error "Stable NIC identity matched more than one interface (${resolved}, ${candidate})."
        exit 1
      fi
      resolved="${candidate}"
    fi
  done

  [[ -n "${resolved}" ]] || {
    log.error "Selected NIC identity no longer exists (pci=${SELECTED_DATA_PCI:-unknown}, mac=${SELECTED_DATA_MAC:-unknown})."
    exit 1
  }
  if [[ "${resolved}" != "${SELECTED_DATA_NIC}" ]]; then
    log "Resolved renamed data NIC ${SELECTED_DATA_NIC} -> ${resolved} from stable PCI/MAC identity."
    SELECTED_DATA_NIC="${resolved}"
  fi
}

probe.selected.data.nic() {
  local was_up=0
  if ip -o link show dev "${SELECTED_DATA_NIC}" | grep -q '<[^>]*UP'; then
    was_up=1
  fi

  restore.probed.nic() {
    if ((was_up == 0)); then
      ip link set dev "${SELECTED_DATA_NIC}" down >/dev/null 2>&1 || true
    fi
  }
  trap restore.probed.nic EXIT INT TERM

  log "Temporarily bringing ${SELECTED_DATA_NIC} up for ${PROBE_SECONDS}s; original state will be restored."
  if ! ip link set dev "${SELECTED_DATA_NIC}" up; then
    log.error "Unable to bring selected data NIC up for probing."
    exit 1
  fi
  sleep "${PROBE_SECONDS}"
  ip -details link show dev "${SELECTED_DATA_NIC}" >&2 || true
  ethtool "${SELECTED_DATA_NIC}" >&2 || true

  restore.probed.nic
  trap - EXIT INT TERM
  log "Temporary probe complete; ${SELECTED_DATA_NIC} administrative state restored."
}

validate.bridge.vids() {
  local vids="$1"
  local token start end
  vids="$(printf '%s' "${vids}" | xargs)"

  [[ -n "${vids}" ]] || {
    log.error "VLAN IDs cannot be empty."
    exit 1
  }
  [[ "${vids}" =~ ^[0-9][0-9\ \-]*$ ]] || {
    log.error "Invalid VLAN ID syntax: ${vids}"
    exit 1
  }

  for token in ${vids}; do
    if [[ "${token}" == *-* ]]; then
      start="${token%-*}"
      end="${token#*-}"
      [[ "${start}" =~ ^[0-9]+$ && "${end}" =~ ^[0-9]+$ ]] || {
        log.error "Invalid VLAN range token: ${token}"
        exit 1
      }
      ((start >= 1 && start <= 4094 && end >= 1 && end <= 4094 && start <= end)) || {
        log.error "VLAN range out of bounds: ${token}"
        exit 1
      }
      if ! is.true "${ALLOW_ALL_VLAN_RANGE}" && ((start == 1 && end == 4094)); then
        log.error "Full VLAN range 1-4094 is blocked by policy."
        exit 1
      fi
      if ! is.true "${ALLOW_VLAN_1}" && ((start <= 1 && end >= 1)); then
        log.error "VLAN 1 is blocked by policy."
        exit 1
      fi
    else
      [[ "${token}" =~ ^[0-9]+$ ]] || {
        log.error "Invalid VLAN token: ${token}"
        exit 1
      }
      ((token >= 1 && token <= 4094)) || {
        log.error "VLAN ID out of bounds: ${token}"
        exit 1
      }
      if ! is.true "${ALLOW_VLAN_1}" && ((token == 1)); then
        log.error "VLAN 1 is blocked by policy."
        exit 1
      fi
    fi
  done
}

validate.selection() {
  local selected_index selected_ip selected_bridge_member selected_speed_evidence
  selected_index="$(lookup.nic.index "${SELECTED_DATA_NIC}" || true)"
  [[ -n "${selected_index}" ]] || {
    log.error "Selected NIC was not found in NIC summary: ${SELECTED_DATA_NIC}"
    exit 1
  }

  selected_ip="${NIC_IP[$selected_index]}"
  selected_bridge_member="${NIC_BRIDGE_MEMBER[$selected_index]}"
  selected_speed_evidence="$(nic.speed.evidence.mbps "${NIC_DRIVER[$selected_index]}" "${NIC_SPEED[$selected_index]}" "${NIC_SUPPORTED_SPEED[$selected_index]}")"

  [[ "${MIN_DATA_SPEED_MBPS}" =~ ^[0-9]+$ ]] && ((MIN_DATA_SPEED_MBPS >= 1000)) || {
    log.error "PROXMOX_VLAN_MIN_DATA_SPEED_MBPS must be an integer of at least 1000."
    exit 1
  }
  if ! nic.meets.minimum.speed "${NIC_DRIVER[$selected_index]}" "${NIC_SPEED[$selected_index]}" "${NIC_SUPPORTED_SPEED[$selected_index]}"; then
    log.error "Selected NIC ${SELECTED_DATA_NIC} has only ${selected_speed_evidence}Mbps of speed evidence; data LAN policy requires at least ${MIN_DATA_SPEED_MBPS}Mbps."
    exit 1
  fi

  if [[ -n "${MGMT_NIC}" && "${SELECTED_DATA_NIC}" == "${MGMT_NIC}" ]] && ! is.true "${ALLOW_SAME_MANAGEMENT_AND_DATA_NIC}"; then
    log.error "Selected data NIC matches management NIC (${MGMT_NIC}) and policy forbids this."
    exit 1
  fi
  if [[ "${selected_ip}" != "-" ]] && ! is.true "${ALLOW_DATA_NIC_WITH_HOST_IP}"; then
    log.error "Selected NIC (${SELECTED_DATA_NIC}) already has host IP (${selected_ip}) and policy forbids this."
    exit 1
  fi
  if ! selected.bridge.member.allowed "${selected_bridge_member}"; then
    log.error "Selected NIC (${SELECTED_DATA_NIC}) belongs to foreign bridge ${selected_bridge_member}; expected unused or ${SELECTED_DATA_BRIDGE}."
    exit 1
  fi
  [[ "${SELECTED_DATA_BRIDGE}" =~ ^[a-zA-Z0-9_.:-]+$ ]] || {
    log.error "Data bridge contains unsupported characters: ${SELECTED_DATA_BRIDGE}"
    exit 1
  }
  case "${SELECTED_DATA_LINK_MODE}" in
    untagged)
      SELECTED_DATA_BRIDGE_VIDS=""
      ;;
    vlan-aware)
      validate.bridge.vids "${SELECTED_DATA_BRIDGE_VIDS}"
      ;;
    *)
      log.error "Data link mode must be untagged or vlan-aware; got: ${SELECTED_DATA_LINK_MODE}"
      exit 1
      ;;
  esac
}

choose.data.nic.interactive() {
  local -a menu_options=()
  local -a menu_indexes=()
  local i choice speed_class recommend_label state_label pci_label

  for i in "${!NIC_IFACE[@]}"; do
    if [[ -n "${MGMT_NIC}" && "${NIC_IFACE[$i]}" == "${MGMT_NIC}" ]]; then
      continue
    fi
    if [[ "${NIC_IP[$i]}" != "-" ]] && ! is.true "${ALLOW_DATA_NIC_WITH_HOST_IP}"; then
      continue
    fi
    if [[ "${NIC_BRIDGE_MEMBER[$i]}" != "-" ]] && ! is.true "${ALLOW_DATA_NIC_BRIDGE_MEMBER}"; then
      continue
    fi
    if ! nic.meets.minimum.speed "${NIC_DRIVER[$i]}" "${NIC_SPEED[$i]}" "${NIC_SUPPORTED_SPEED[$i]}"; then
      continue
    fi

    speed_class="$(nic.speed.class "${NIC_DRIVER[$i]}" "${NIC_SPEED[$i]}" "${NIC_SUPPORTED_SPEED[$i]}")"
    recommend_label="$(nic.recommendation.label "${NIC_ROLE[$i]}" "${NIC_SCORE[$i]}" "${NIC_DRIVER[$i]}")"
    state_label="${NIC_OPERSTATE[$i]}"
    if [[ "${NIC_CARRIER[$i]}" == "0" && "${state_label}" != "-" ]]; then
      state_label="${state_label}/unplugged"
    fi
    pci_label="${NIC_PCI_LABEL[$i]}"
    if [[ "${pci_label}" == "-" && "${NIC_DRIVER[$i]}" == "ixgbe" ]]; then
      pci_label="Intel X540"
    fi

    menu_options+=("${NIC_IFACE[$i]} | ${pci_label} | ${speed_class} | driver=${NIC_DRIVER[$i]} | pci=${NIC_PCI[$i]} | mac=${NIC_MAC[$i]} | ip=${NIC_IP[$i]} | bridge=${NIC_BRIDGE_MEMBER[$i]} | state=${state_label} | ${recommend_label}")
    menu_indexes+=("${i}")
  done
  menu_options+=("abort")

  if ((${#menu_indexes[@]} == 0)); then
    log.error "No unused physical data NICs with at least ${MIN_DATA_SPEED_MBPS}Mbps capability were found in ${HARDWARE_NICS_TSV}."
    exit 1
  fi

  printf '\nSelectable VM/LXC data NICs:\n\n' >&3

  choice="$(menu.tty "Select VM/LXC data NIC:" "${menu_options[@]}")"
  if ((choice == ${#menu_options[@]})); then
    log.error "Operator aborted NIC selection."
    exit 1
  fi

  i="${menu_indexes[$((choice - 1))]}"
  SELECTED_DATA_NIC="${NIC_IFACE[$i]}"
  SELECTED_DATA_DRIVER="${NIC_DRIVER[$i]}"
  SELECTED_DATA_PCI="${NIC_PCI[$i]}"
  SELECTED_DATA_MAC="${NIC_PERMANENT_MAC[$i]}"
  if [[ -z "${SELECTED_DATA_MAC}" || "${SELECTED_DATA_MAC}" == "-" ]]; then
    SELECTED_DATA_MAC="${NIC_MAC[$i]}"
  fi
}

select.mode.interactive() {
  local choice
  choice="$(menu.tty "Select data-bridge execution mode (current: ${FEATURE_MODE}):" "preflight (read-only validation)" "probe (temporarily bring selected link up, then restore)" "write (write config + dry-run reload)" "apply (write + reload + verify/rollback)")"
  case "${choice}" in
    1) FEATURE_MODE="preflight" ;;
    2) FEATURE_MODE="probe" ;;
    3) FEATURE_MODE="write" ;;
    4) FEATURE_MODE="apply" ;;
    *) log.error "Invalid mode selection"; exit 1 ;;
  esac
}

write.selection.file() {
  mkdir -p "${FACTS_DIR}"
  cat > "${VLAN_SELECTION_PATH}" <<EOF
---
proxmox_vlan_operator_selection:
  confirmed: true
  source: "setup/vlan.sh"
  management:
    bridge: $(yaml.quote "${MGMT_BRIDGE}")
    nic: $(yaml.scalar.or.null "${MGMT_NIC}")
    ip_cidr: $(yaml.scalar.or.null "${MGMT_IP_CIDR}")
    gateway: $(yaml.scalar.or.null "${MGMT_GATEWAY}")
    gui_port: ${MGMT_GUI_PORT}
  data:
    bridge: $(yaml.quote "${SELECTED_DATA_BRIDGE}")
    nic: $(yaml.quote "${SELECTED_DATA_NIC}")
    expected_driver: $(yaml.scalar.or.null "${SELECTED_DATA_DRIVER}")
    expected_pci: $(yaml.scalar.or.null "${SELECTED_DATA_PCI}")
    expected_mac: $(yaml.scalar.or.null "${SELECTED_DATA_MAC}")
    link_mode: $(yaml.quote "${SELECTED_DATA_LINK_MODE}")
    bridge_vlan_aware: $(if [[ "${SELECTED_DATA_LINK_MODE}" == "vlan-aware" ]]; then printf true; else printf false; fi)
    bridge_vids: $(yaml.quote "${SELECTED_DATA_BRIDGE_VIDS}")
    host_ip: ${SELECTED_DATA_HOST_IP}
  safety:
    minimum_data_speed_mbps: ${MIN_DATA_SPEED_MBPS}
    oob_console_ack: ${SELECTION_OOB_ACK}
EOF
  log "Persisted operator selection: ${VLAN_SELECTION_PATH}"
}

ensure.data.link.ready() {
  local link_interactive="0"
  is.true "${FEATURE_INTERACTIVE}" && link_interactive="1"
  [[ -x "${NETWORK_LINK_RUNNER_PATH}" ]] || {
    log.error "DATA-Link runner is unavailable: ${NETWORK_LINK_RUNNER_PATH}"
    exit 1
  }
  log "Delegating physical DATA-Link activation and carrier verification."
  PROXMOX_NETWORK_LINK_NIC="${SELECTED_DATA_NIC}" \
  PROXMOX_NETWORK_LINK_EXPECTED_PCI="${SELECTED_DATA_PCI}" \
  PROXMOX_NETWORK_LINK_EXPECTED_MAC="${SELECTED_DATA_MAC}" \
  PROXMOX_NETWORK_LINK_EXPECTED_BRIDGE="${SELECTED_DATA_BRIDGE}" \
  PROXMOX_NETWORK_LINK_MIN_SPEED_MBPS="${MIN_DATA_SPEED_MBPS}" \
  PROXMOX_NETWORK_LINK_FACTS_DIR="${FACTS_DIR}" \
  PROXMOX_NETWORK_LINK_SELECTION_PATH="${NETWORK_LINK_SELECTION_PATH}" \
  PROXMOX_NETWORK_LINK_READY_PATH="${NETWORK_LINK_READY_PATH}" \
  PROXMOX_NETWORK_LINK_INTERACTIVE="${link_interactive}" \
  PROXMOX_NETWORK_LINK_CONFIRM_UP="${PROXMOX_NETWORK_LINK_CONFIRM_UP:-}" \
    bash "${NETWORK_LINK_RUNNER_PATH}" up
}

promote.applied.selection() {
  [[ -s "${VLAN_SELECTION_PATH}" ]] || {
    log.error "Cannot promote missing pending selection: ${VLAN_SELECTION_PATH}"
    exit 1
  }
  install -m 0600 "${VLAN_SELECTION_PATH}" "${VLAN_APPLIED_SELECTION_PATH}"
  install -m 0600 "${VLAN_SELECTION_PATH}" "${VLAN_COMPAT_SELECTION_PATH}"
  log "Promoted verified DATA-Link state: ${VLAN_APPLIED_SELECTION_PATH}"
}

collect.operator.selection() {
  local interactive_ui=0
  local confirm_choice oob_choice reuse_choice
  local selected_index

  [[ -f "${HARDWARE_FACTS_PATH}" ]] || {
    log.error "Missing hardware facts: ${HARDWARE_FACTS_PATH}"
    exit 1
  }

  load.nic.summary
  build.management.snapshot
  load.management.from.hardware.facts
  load.persisted.selection || true
  assess.persisted.selection || true

  if is.true "${FEATURE_INTERACTIVE}" && open.tty; then
    interactive_ui=1
  fi

  if ((interactive_ui == 1)); then
    printf '\nDetected Proxmox admin path:\n' >&3
    printf '  GUI port:       %s\n' "${MGMT_GUI_PORT}" >&3
    printf '  bridge:         %s\n' "${MGMT_BRIDGE}" >&3
    printf '  management NIC: %s\n' "${MGMT_NIC:-unknown}" >&3
    printf '  IP/CIDR:        %s\n' "${MGMT_IP_CIDR:-unknown}" >&3
    printf '  gateway:        %s\n\n' "${MGMT_GATEWAY:-unknown}" >&3

    confirm_choice="$(menu.tty "Confirm this is the Proxmox GUI/admin network path:" "yes" "abort")"
    if [[ "${confirm_choice}" != "1" ]]; then
      log.error "Operator aborted management path confirmation."
      exit 1
    fi

    if ((PERSISTED_SELECTION_REUSABLE == 1)); then
      printf 'Existing feature-owned DATA-Link selection:\n' >&3
      printf '  physical NIC: %s\n' "${PERSISTED_DATA_NIC}" >&3
      printf '  data bridge:  %s\n' "${PERSISTED_DATA_BRIDGE}" >&3
      printf '  link mode:    %s\n' "${PERSISTED_DATA_LINK_MODE:-untagged}" >&3
      printf '  assessment:   %s\n\n' "${PERSISTED_SELECTION_REASON}" >&3
      reuse_choice="$(menu.tty "Choose DATA-Link selection:" "reuse/repair the feature-owned selection" "select a different unused physical NIC" "abort")"
      case "${reuse_choice}" in
        1) apply.persisted.selection ;;
        2) ;;
        *) log.error "Operator aborted DATA-Link selection."; exit 1 ;;
      esac
    elif ((PERSISTED_SELECTION_FOUND == 1)); then
      log.warn "Persisted DATA-Link selection cannot be reused: ${PERSISTED_SELECTION_REASON}"
    fi

    if ((PERSISTED_SELECTION_REUSED == 0)); then
      choose.data.nic.interactive
      SELECTED_DATA_BRIDGE="${DEFAULT_DATA_BRIDGE:-$(suggest.data.bridge)}"
      SELECTED_DATA_BRIDGE="$(prompt.tty "Enter data bridge name" "${SELECTED_DATA_BRIDGE}")"
      SELECTED_DATA_LINK_MODE="${DEFAULT_LINK_MODE}"
      SELECTED_DATA_BRIDGE_VIDS="${DEFAULT_BRIDGE_VIDS}"
      confirm_choice="$(menu.tty "Select physical data-link mode:" "untagged local DATA-Link" "VLAN-aware trunk")"
      case "${confirm_choice}" in
        1) SELECTED_DATA_LINK_MODE="untagged"; SELECTED_DATA_BRIDGE_VIDS="" ;;
        2)
          SELECTED_DATA_LINK_MODE="vlan-aware"
          SELECTED_DATA_BRIDGE_VIDS="$(prompt.tty "Enter VLAN IDs/ranges (space separated)" "${SELECTED_DATA_BRIDGE_VIDS:-10}")"
          ;;
        *) log.error "Invalid data-link mode selection."; exit 1 ;;
      esac
    fi
    ((FEATURE_MODE_EXPLICIT == 1)) || select.mode.interactive

    if [[ "${FEATURE_MODE}" == "preflight" || "${FEATURE_MODE}" == "probe" ]]; then
      SELECTION_OOB_ACK="false"
      FEATURE_OOB_ACK="${FEATURE_OOB_ACK:-NO}"
    else
      oob_choice="$(menu.tty "Confirm out-of-band console access is available:" "yes" "abort")"
      if [[ "${oob_choice}" != "1" ]]; then
        log.error "Operator aborted because OOB console was not confirmed."
        exit 1
      fi
      SELECTION_OOB_ACK="true"
      FEATURE_OOB_ACK="YES"
    fi
  else
    SELECTED_DATA_NIC="${PROXMOX_VLAN_DATA_NIC:-}"
    if [[ -z "${SELECTED_DATA_NIC}" && "${PERSISTED_SELECTION_REUSABLE}" == 1 ]]; then
      apply.persisted.selection
      log "Reusing verified feature-owned DATA-Link selection in non-interactive mode."
    else
      [[ -n "${SELECTED_DATA_NIC}" ]] || {
        log.error "Interactive UI unavailable. Set PROXMOX_VLAN_DATA_NIC or create a reusable feature selection first."
        exit 1
      }
      SELECTED_DATA_BRIDGE="${DEFAULT_DATA_BRIDGE:-$(suggest.data.bridge)}"
      SELECTED_DATA_LINK_MODE="${DEFAULT_LINK_MODE}"
      SELECTED_DATA_BRIDGE_VIDS="${DEFAULT_BRIDGE_VIDS}"
      selected_index="$(lookup.nic.index "${SELECTED_DATA_NIC}" || true)"
      if [[ -n "${selected_index}" ]]; then
        SELECTED_DATA_DRIVER="${NIC_DRIVER[$selected_index]}"
        SELECTED_DATA_PCI="${NIC_PCI[$selected_index]}"
        SELECTED_DATA_MAC="${NIC_PERMANENT_MAC[$selected_index]}"
        if [[ -z "${SELECTED_DATA_MAC}" || "${SELECTED_DATA_MAC}" == "-" ]]; then
          SELECTED_DATA_MAC="${NIC_MAC[$selected_index]}"
        fi
      fi
    fi

    if [[ "${FEATURE_MODE}" == "preflight" || "${FEATURE_MODE}" == "probe" ]]; then
      SELECTION_OOB_ACK="false"
    else
      if is.true "${FEATURE_OOB_ACK}"; then
        FEATURE_OOB_ACK="YES"
        SELECTION_OOB_ACK="true"
      else
        SELECTION_OOB_ACK="false"
      fi
    fi
  fi

  require.valid.mode
  resolve.selected.nic.identity
  validate.selection
  write.selection.file
}

use.local.feature.files() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"

  if [[ -r "${repo_root}/ansible/${HARDWARE_PLAYBOOK_REL}" \
    && -r "${repo_root}/ansible/${VLAN_PLAYBOOK_REL}" \
    && -r "${repo_root}/ansible/${VLAN_TASKS_REL}" \
    && -r "${repo_root}/ansible/${VLAN_TEMPLATE_REL}" \
    && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]]; then
    PLAYBOOK_ROOT="${repo_root}/ansible"
    PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
    GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
    HARDWARE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${HARDWARE_PLAYBOOK_REL}"
    VLAN_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${VLAN_PLAYBOOK_REL}"
    VLAN_TASKS_PATH="${PLAYBOOK_ROOT}/${VLAN_TASKS_REL}"
    VLAN_TEMPLATE_PATH="${PLAYBOOK_ROOT}/${VLAN_TEMPLATE_REL}"
    NETWORK_LINK_RUNNER_PATH="${repo_root}/setup/network-link.sh"
    log "Using local feature files from ${repo_root}."
    return 0
  fi

  return 1
}

fetch.feature.file() {
  local url dest
  url="$1"
  dest="$2"
  mkdir -p "$(dirname "${dest}")"
  log "Fetching feature file: ${url}"
  if ! wget -qO "${dest}" "${url}"; then
    log.error "Failed to fetch feature file: ${url}"
    exit 1
  fi
  if [[ ! -s "${dest}" ]]; then
    log.error "Feature file is empty: ${url}"
    exit 1
  fi
}

prepare.feature.files() {
  if use.local.feature.files; then
    return
  fi

  mkdir -p "${PLAYBOOK_GROUP_VARS_DIR}"
  fetch.feature.file "${GROUP_VARS_URL}" "${GROUP_VARS_PATH}"
  fetch.feature.file "${HARDWARE_PLAYBOOK_URL}" "${HARDWARE_PLAYBOOK_PATH}"
  fetch.feature.file "${VLAN_PLAYBOOK_URL}" "${VLAN_PLAYBOOK_PATH}"
  fetch.feature.file "${VLAN_TASKS_URL}" "${VLAN_TASKS_PATH}"
  fetch.feature.file "${VLAN_TEMPLATE_URL}" "${VLAN_TEMPLATE_PATH}"
  fetch.feature.file "${NETWORK_LINK_RUNNER_URL}" "${NETWORK_LINK_RUNNER_PATH}"
  chmod 0755 "${NETWORK_LINK_RUNNER_PATH}"
}

run.feature.playbook() {
  local playbook_path="$1"
  shift
  ansible.runtime.run -i localhost, -c local -e "@${GROUP_VARS_PATH}" "$@" "${playbook_path}"
}

write.vlan.extra.vars.file() {
  local discovery_enabled_yaml

  discovery_enabled_yaml="$(bool.yaml "${FEATURE_USE_DISCOVERY}")"
  mkdir -p "${TMP_DIR}"

  cat > "${VLAN_EXTRA_VARS_PATH}" <<EOF
---
proxmox_feature_defaults:
  vlan:
    enabled: true
    mode: $(yaml.quote "${FEATURE_MODE}")
    use_discovered_hardware: ${discovery_enabled_yaml}
    require_operator_selection: true

proxmox_feature_facts_dir: $(yaml.quote "${FACTS_DIR}")
proxmox_hardware_facts_path: $(yaml.quote "${HARDWARE_FACTS_PATH}")
proxmox_hardware_nics_tsv_path: $(yaml.quote "${HARDWARE_NICS_TSV}")
proxmox_vlan_selection_path: $(yaml.quote "${VLAN_SELECTION_PATH}")
proxmox_vlan_minimum_data_speed_mbps: ${MIN_DATA_SPEED_MBPS}
EOF

  log "Prepared VLAN extra-vars: ${VLAN_EXTRA_VARS_PATH}"
}

run.vlan.feature() {
  log "Running Proxmox hardware discovery helper..."
  run.feature.playbook "${HARDWARE_PLAYBOOK_PATH}"
  collect.operator.selection
  require.oob.ack

  if [[ "${FEATURE_MODE}" == "probe" ]]; then
    probe.selected.data.nic
    return 0
  fi

  if [[ "${FEATURE_MODE}" == "apply" ]]; then
    ensure.data.link.ready
  fi

  log "Running Proxmox data-bridge feature in mode=${FEATURE_MODE}..."
  write.vlan.extra.vars.file
  run.feature.playbook \
    "${VLAN_PLAYBOOK_PATH}" \
    -e "@${VLAN_EXTRA_VARS_PATH}"
  if [[ "${FEATURE_MODE}" == "apply" ]]; then
    promote.applied.selection
  fi
}

main() {
  require.root
  require.apt
  require.proxmox
  require.valid.mode
  require.host.network.ready
  ensure.managed.ansible
  prepare.feature.files
  run.vlan.feature
}

if ! is.true "${PROXMOX_VLAN_SOURCE_ONLY:-0}"; then
  main "$@"
fi
