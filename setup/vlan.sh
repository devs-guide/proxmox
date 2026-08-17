#!/usr/bin/env bash
## Manual Proxmox VLAN feature runner.
## Local usage:
##   ./setup/vlan.sh [preflight|write|apply]
## Published usage:
##   wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash

set -euo pipefail

log()       { printf '[setup.vlan] %s\n' "$*" >&2; }
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
HARDWARE_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[0]}"
VLAN_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[1]}"
HARDWARE_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${HARDWARE_PLAYBOOK_REL}"
HARDWARE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${HARDWARE_PLAYBOOK_REL}"
VLAN_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${VLAN_PLAYBOOK_REL}"
VLAN_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${VLAN_PLAYBOOK_REL}"
VLAN_EXTRA_VARS_PATH="${TMP_DIR}/vlan.extra-vars.yml"
ANSIBLE_VENV="/opt/ansible-venv"
ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
ANSIBLE_CORE_VERSION="2.20.5"
ANSIBLE_CORE_SPEC="ansible-core==${ANSIBLE_CORE_VERSION}"
PYTHON_VERSION="3.12.3"
PYTHON_MAJOR_MINOR="3.12"
PYTHON_SOURCE_PREFIX="/usr/local"
PYTHON_BIN="${PYTHON_SOURCE_PREFIX}/bin/python${PYTHON_MAJOR_MINOR}"
PYTHON_SRC_DIR="${PYTHON_SOURCE_PREFIX}/src/Python-${PYTHON_VERSION}"
PYTHON_SRC_ARCHIVE="${PYTHON_SRC_DIR}.tgz"
PYTHON_SRC_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"
MANAGED_TARGET_PYTHON_HOME="/opt/ansible/py312"
MANAGED_TARGET_PYTHON_PATH="${MANAGED_TARGET_PYTHON_HOME}/bin/python"
MANAGED_TARGET_HANDOFF_MARKER="${MANAGED_TARGET_PYTHON_HOME}/.handoff-ready"
PYTHON_BOOTSTRAP_BIN=""
FEATURE_MODE="${1:-${PROXMOX_VLAN_MODE:-preflight}}"
FEATURE_USE_DISCOVERY="${PROXMOX_VLAN_USE_DISCOVERY:-true}"
FEATURE_BASELINE_BYPASS="${PROXMOX_FEATURE_SKIP_BASELINE_CHECK:-0}"
FEATURE_OOB_ACK="${PROXMOX_VLAN_CONFIRM_OOB:-}"
FEATURE_INTERACTIVE="${PROXMOX_VLAN_INTERACTIVE:-1}"
FACTS_DIR="${PROXMOX_VLAN_FACTS_DIR:-/etc/ansible/proxmox/facts}"
HARDWARE_FACTS_PATH="${PROXMOX_VLAN_HARDWARE_FACTS_PATH:-${FACTS_DIR}/hardware.yml}"
HARDWARE_NICS_TSV="${PROXMOX_VLAN_HARDWARE_NICS_TSV:-${FACTS_DIR}/hardware.nics.tsv}"
VLAN_SELECTION_PATH="${PROXMOX_VLAN_SELECTION_PATH:-${FACTS_DIR}/vlan.selection.yml}"
DEFAULT_DATA_BRIDGE="${PROXMOX_VLAN_DATA_BRIDGE:-vmbr1}"
DEFAULT_BRIDGE_VIDS="${PROXMOX_VLAN_BRIDGE_VIDS:-10 20 30 40}"
ALLOW_VLAN_1="${PROXMOX_VLAN_ALLOW_VLAN_1:-false}"
ALLOW_ALL_VLAN_RANGE="${PROXMOX_VLAN_ALLOW_ALL_VLAN_RANGE:-false}"
ALLOW_SAME_MANAGEMENT_AND_DATA_NIC="${PROXMOX_VLAN_ALLOW_SAME_MANAGEMENT_AND_DATA_NIC:-false}"
ALLOW_DATA_NIC_WITH_HOST_IP="${PROXMOX_VLAN_ALLOW_DATA_NIC_WITH_HOST_IP:-false}"
ALLOW_DATA_NIC_BRIDGE_MEMBER="${PROXMOX_VLAN_ALLOW_DATA_NIC_BRIDGE_MEMBER:-false}"

declare -a NIC_IFACE=()
declare -a NIC_ROLE=()
declare -a NIC_SCORE=()
declare -a NIC_SPEED=()
declare -a NIC_DRIVER=()
declare -a NIC_PCI=()
declare -a NIC_PCI_LABEL=()
declare -a NIC_MAC=()
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
SELECTED_DATA_BRIDGE_VIDS=""
SELECTED_DATA_DRIVER=""
SELECTED_DATA_PCI=""
SELECTED_DATA_HOST_IP="null"
SELECTION_OOB_ACK="false"

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
    preflight|write|apply) ;;
    *)
      log.error "Unsupported mode: ${FEATURE_MODE}"
      log.error "Use one of: preflight, write, apply"
      exit 1
      ;;
  esac
}

require.baseline.ready() {
  if [[ "${FEATURE_BASELINE_BYPASS}" == "1" ]]; then
    log "Skipping baseline readiness gate because PROXMOX_FEATURE_SKIP_BASELINE_CHECK=1."
    return
  fi

  if [[ ! -x "${MANAGED_TARGET_PYTHON_PATH}" ]]; then
    log.error "Managed target Python not found at ${MANAGED_TARGET_PYTHON_PATH}."
    log.error "Run the baseline bootstrap first, then rerun this feature."
    exit 1
  fi

  if [[ ! -f "${MANAGED_TARGET_HANDOFF_MARKER}" ]]; then
    log.error "Baseline handoff marker not found at ${MANAGED_TARGET_HANDOFF_MARKER}."
    log.error "Run the baseline bootstrap first, then rerun this feature."
    exit 1
  fi

  if [[ ! -f /etc/network/interfaces ]]; then
    log.error "/etc/network/interfaces is missing."
    exit 1
  fi
}

require.oob.ack() {
  if [[ "${FEATURE_MODE}" == "preflight" ]]; then
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

  if [[ "${speed}" =~ ^[0-9]+$ ]]; then
    if (( speed >= 10000 )); then
      printf '10GbE-class'
      return
    fi
    if (( speed >= 1000 )); then
      printf '1GbE-class'
      return
    fi
  fi

  case "${driver}" in
    ixgbe|i40e|ice|mlx5_core|bnxt_en|atlantic)
      printf '10GbE-class'
      ;;
    igb|e1000e|igc|tg3|r8169)
      printf '1GbE-class'
      ;;
    *)
      printf 'unknown-class'
      ;;
  esac
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
  local default_route_device
  default_route_device="$(ip route show default | awk 'NR==1 {print $5}')"
  MGMT_GATEWAY="$(ip route show default | awk 'NR==1 {print $3}')"

  if [[ "${default_route_device}" =~ ^vmbr[0-9]+$ ]]; then
    MGMT_BRIDGE="${default_route_device}"
  else
    MGMT_BRIDGE="vmbr0"
  fi

  MGMT_NIC="$(
    bridge link 2>/dev/null \
      | awk -v bridge="${MGMT_BRIDGE}" '
          $0 ~ (" master " bridge " ") {
            nic=$2
            sub(/@.*/, "", nic)
            sub(/:/, "", nic)
            print nic
            exit
          }
        '
  )"
  if [[ -z "${MGMT_NIC}" && -n "${default_route_device}" && ! "${default_route_device}" =~ ^vmbr[0-9]+$ ]]; then
    MGMT_NIC="${default_route_device}"
  fi

  MGMT_IP_CIDR="$(ip -o -4 addr show dev "${MGMT_BRIDGE}" 2>/dev/null | awk 'NR==1 {print $4}')"
  if [[ -z "${MGMT_IP_CIDR}" && -n "${MGMT_NIC}" ]]; then
    MGMT_IP_CIDR="$(ip -o -4 addr show dev "${MGMT_NIC}" 2>/dev/null | awk 'NR==1 {print $4}')"
  fi
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

load.nic.summary() {
  local row field_count
  local iface role score speed driver pci pci_label mac ip_cidr bridge_member operstate carrier reason
  [[ -f "${HARDWARE_NICS_TSV}" ]] || {
    log.error "Missing NIC summary: ${HARDWARE_NICS_TSV}"
    exit 1
  }

  NIC_IFACE=()
  NIC_ROLE=()
  NIC_SCORE=()
  NIC_SPEED=()
  NIC_DRIVER=()
  NIC_PCI=()
  NIC_PCI_LABEL=()
  NIC_MAC=()
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
    driver=""
    pci=""
    pci_label=""
    mac=""
    ip_cidr=""
    bridge_member=""
    operstate=""
    carrier=""
    reason=""

    if [[ "${field_count}" -ge 13 ]]; then
      IFS=$'\t' read -r iface role score speed driver pci pci_label mac ip_cidr bridge_member operstate carrier reason <<< "${row}"
    else
      IFS=$'\t' read -r iface role score speed driver pci mac ip_cidr bridge_member operstate carrier reason <<< "${row}"
    fi

    [[ -n "${iface:-}" ]] || continue
    NIC_IFACE+=("${iface}")
    NIC_ROLE+=("${role:-other}")
    NIC_SCORE+=("${score:-0}")
    NIC_SPEED+=("${speed:-"-"}")
    NIC_DRIVER+=("${driver:-"-"}")
    NIC_PCI+=("${pci:-"-"}")
    NIC_PCI_LABEL+=("${pci_label:-"-"}")
    NIC_MAC+=("${mac:-"-"}")
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
  local selected_index selected_ip selected_bridge_member
  selected_index="$(lookup.nic.index "${SELECTED_DATA_NIC}" || true)"
  [[ -n "${selected_index}" ]] || {
    log.error "Selected NIC was not found in NIC summary: ${SELECTED_DATA_NIC}"
    exit 1
  }

  selected_ip="${NIC_IP[$selected_index]}"
  selected_bridge_member="${NIC_BRIDGE_MEMBER[$selected_index]}"

  if [[ -n "${MGMT_NIC}" && "${SELECTED_DATA_NIC}" == "${MGMT_NIC}" ]] && ! is.true "${ALLOW_SAME_MANAGEMENT_AND_DATA_NIC}"; then
    log.error "Selected data NIC matches management NIC (${MGMT_NIC}) and policy forbids this."
    exit 1
  fi
  if [[ "${selected_ip}" != "-" ]] && ! is.true "${ALLOW_DATA_NIC_WITH_HOST_IP}"; then
    log.error "Selected NIC (${SELECTED_DATA_NIC}) already has host IP (${selected_ip}) and policy forbids this."
    exit 1
  fi
  if [[ "${selected_bridge_member}" != "-" ]] && ! is.true "${ALLOW_DATA_NIC_BRIDGE_MEMBER}"; then
    log.error "Selected NIC (${SELECTED_DATA_NIC}) already belongs to bridge ${selected_bridge_member} and policy forbids this."
    exit 1
  fi
  [[ "${SELECTED_DATA_BRIDGE}" =~ ^vmbr[0-9]+$ ]] || {
    log.error "Data bridge must match vmbr<id>; got: ${SELECTED_DATA_BRIDGE}"
    exit 1
  }
  validate.bridge.vids "${SELECTED_DATA_BRIDGE_VIDS}"
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

    speed_class="$(nic.speed.class "${NIC_DRIVER[$i]}" "${NIC_SPEED[$i]}")"
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
    log.error "No selectable data NICs were found in ${HARDWARE_NICS_TSV}."
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
}

select.mode.interactive() {
  local choice
  choice="$(menu.tty "Select VLAN execution mode (current: ${FEATURE_MODE}):" "preflight (validate only)" "write (write config + dry-run reload)" "apply (write + reload)")"
  case "${choice}" in
    1) FEATURE_MODE="preflight" ;;
    2) FEATURE_MODE="write" ;;
    3) FEATURE_MODE="apply" ;;
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
    bridge_vlan_aware: true
    bridge_vids: $(yaml.quote "${SELECTED_DATA_BRIDGE_VIDS}")
    host_ip: ${SELECTED_DATA_HOST_IP}
  safety:
    oob_console_ack: ${SELECTION_OOB_ACK}
EOF
  log "Persisted operator selection: ${VLAN_SELECTION_PATH}"
}

collect.operator.selection() {
  local interactive_ui=0
  local confirm_choice oob_choice
  local selected_index

  [[ -f "${HARDWARE_FACTS_PATH}" ]] || {
    log.error "Missing hardware facts: ${HARDWARE_FACTS_PATH}"
    exit 1
  }

  load.nic.summary
  build.management.snapshot
  load.management.from.hardware.facts
  SELECTED_DATA_BRIDGE="${DEFAULT_DATA_BRIDGE}"
  SELECTED_DATA_BRIDGE_VIDS="${DEFAULT_BRIDGE_VIDS}"

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

    choose.data.nic.interactive
    SELECTED_DATA_BRIDGE="$(prompt.tty "Enter data bridge name" "${SELECTED_DATA_BRIDGE}")"
    SELECTED_DATA_BRIDGE_VIDS="$(prompt.tty "Enter VLAN IDs/ranges (space separated)" "${SELECTED_DATA_BRIDGE_VIDS}")"
    select.mode.interactive

    if [[ "${FEATURE_MODE}" == "preflight" ]]; then
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
    [[ -n "${SELECTED_DATA_NIC}" ]] || {
      log.error "Interactive UI unavailable. Set PROXMOX_VLAN_DATA_NIC for non-interactive mode."
      exit 1
    }

    selected_index="$(lookup.nic.index "${SELECTED_DATA_NIC}" || true)"
    if [[ -n "${selected_index}" ]]; then
      SELECTED_DATA_DRIVER="${NIC_DRIVER[$selected_index]}"
      SELECTED_DATA_PCI="${NIC_PCI[$selected_index]}"
    fi

    if [[ "${FEATURE_MODE}" == "preflight" ]]; then
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
  validate.selection
  write.selection.file
}

use.local.feature.files() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"

  if [[ -r "${repo_root}/ansible/${HARDWARE_PLAYBOOK_REL}" && -r "${repo_root}/ansible/${VLAN_PLAYBOOK_REL}" && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]]; then
    PLAYBOOK_ROOT="${repo_root}/ansible"
    PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
    GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
    HARDWARE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${HARDWARE_PLAYBOOK_REL}"
    VLAN_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${VLAN_PLAYBOOK_REL}"
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
EOF

  log "Prepared VLAN extra-vars: ${VLAN_EXTRA_VARS_PATH}"
}

run.vlan.feature() {
  log "Running Proxmox hardware discovery helper..."
  run.feature.playbook "${HARDWARE_PLAYBOOK_PATH}"
  collect.operator.selection
  require.oob.ack

  log "Running Proxmox VLAN feature in mode=${FEATURE_MODE}..."
  write.vlan.extra.vars.file
  run.feature.playbook \
    "${VLAN_PLAYBOOK_PATH}" \
    -e "@${VLAN_EXTRA_VARS_PATH}"
}

main() {
  require.root
  require.apt
  require.proxmox
  require.valid.mode
  require.baseline.ready
  ensure.managed.ansible
  prepare.feature.files
  run.vlan.feature
}

main "$@"
