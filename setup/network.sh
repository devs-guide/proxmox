#!/usr/bin/env bash
## Proxmox network preflight + update feature runner.
## Local usage:
##   ./setup/network.sh [preflight|update|report|all|debug]
## Published usage:
##   wget -qO- https://devs-guide.github.io/proxmox/setup/network.sh | bash

set -Eeuo pipefail

log() {
  printf '[setup.network] %s\n' "$*" >&2
  if [[ -n "${TRACE_PATH:-}" ]]; then
    printf '[setup.network] %s\n' "$*" >> "${TRACE_PATH}"
  fi
  return 0
}
log.error() { printf '[setup.network][error] %s\n' "$*" >&2; }
log.warn()  { printf '[setup.network][warn] %s\n' "$*" >&2; }

CLI_ARG_COUNT="$#"
CLI_MODE_RAW="${1:-}"
FEATURE_MODE="${CLI_MODE_RAW:-${PROXMOX_NETWORK_MODE:-preflight}}"
OUTPUT_ROOT="${PROXMOX_NETWORK_OUTPUT_ROOT:-${HOME:-/root}/proxmox.network.preflight}"
REPORT_DIR_OVERRIDE="${PROXMOX_NETWORK_REPORT_DIR:-}"
SNAPSHOT_DIR_OVERRIDE="${PROXMOX_NETWORK_SNAPSHOT_DIR:-}"
EXPECTED_ADMIN_BRIDGE="${PROXMOX_NETWORK_EXPECTED_ADMIN_BRIDGE:-}"
EXPECTED_DATA_BRIDGE="${PROXMOX_NETWORK_EXPECTED_DATA_BRIDGE:-}"
EXPECTED_DATA_LINK_MODE="${PROXMOX_NETWORK_EXPECTED_DATA_LINK_MODE:-}"
EXPECTED_MANAGEMENT_CIDR="${PROXMOX_NETWORK_MANAGEMENT_CIDR:-${PROXMOX_NETWORK_EXPECTED_LAN_CIDR:-}}"
EXPECTED_DATA_CIDR="${PROXMOX_NETWORK_DATA_CIDR:-}"
MIN_DATA_SPEED_MBPS="${PROXMOX_NETWORK_MIN_DATA_SPEED_MBPS:-1000}"
EXPECTED_GUEST_ADMIN_IF="${PROXMOX_NETWORK_EXPECTED_GUEST_ADMIN_IF:-}"
EXPECTED_GUEST_DATA_IF="${PROXMOX_NETWORK_EXPECTED_GUEST_DATA_IF:-}"
CTID_FILTER="${PROXMOX_NETWORK_CTIDS:-}"
VMID_FILTER="${PROXMOX_NETWORK_VMIDS:-}"
FEATURE_INTERACTIVE="${PROXMOX_NETWORK_INTERACTIVE:-1}"
FEATURE_DEBUG="${PROXMOX_NETWORK_DEBUG:-0}"
PROXMOX_NETWORK_UPDATE_MODE="${PROXMOX_NETWORK_UPDATE_MODE:-check}"
PROXMOX_NETWORK_UPDATE_AUTO_APPLY="${PROXMOX_NETWORK_UPDATE_AUTO_APPLY:-0}"
PROXMOX_NETWORK_UPDATE_VLAN_TAG="${PROXMOX_NETWORK_UPDATE_VLAN_TAG:-}"
PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS="${PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS:-}"
PROXMOX_NETWORK_UPDATE_VM_MODEL="${PROXMOX_NETWORK_UPDATE_VM_MODEL:-virtio}"
PROXMOX_NETWORK_UPDATE_LXCS="${PROXMOX_NETWORK_UPDATE_LXCS:-}"
PROXMOX_NETWORK_UPDATE_VMS="${PROXMOX_NETWORK_UPDATE_VMS:-}"
PROXMOX_NETWORK_UPDATE_LXC_STRATEGY="${PROXMOX_NETWORK_UPDATE_LXC_STRATEGY:-add_data_nic}"
PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR="${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR:-}"
PROXMOX_NETWORK_DEFAULT_DATA_PREFIX="${PROXMOX_NETWORK_DEFAULT_DATA_PREFIX:-24}"
PROXMOX_NETWORK_ALLOW_UNPROBED_DATA_IP="${PROXMOX_NETWORK_ALLOW_UNPROBED_DATA_IP:-0}"
PROXMOX_NETWORK_ALLOW_LXC_RESTART="${PROXMOX_NETWORK_ALLOW_LXC_RESTART:-0}"

TMP_DIR="/tmp/pve-feature-network"
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
  "proxmox/helper/network.preflight.export.yml"
  "proxmox/network.update.yml"
  "proxmox/network.verify.yml"
)
FEATURE_SUPPORT_FILES=(
  "proxmox/helper/network.lxc_nic.py"
)
NETWORK_EXPORT_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[0]}"
NETWORK_UPDATE_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[1]}"
NETWORK_VERIFY_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[2]}"
NETWORK_LXC_NIC_HELPER_REL="${FEATURE_SUPPORT_FILES[0]}"
NETWORK_EXPORT_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${NETWORK_EXPORT_PLAYBOOK_REL}"
NETWORK_UPDATE_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${NETWORK_UPDATE_PLAYBOOK_REL}"
NETWORK_VERIFY_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${NETWORK_VERIFY_PLAYBOOK_REL}"
NETWORK_LXC_NIC_HELPER_URL="${PAGES_BASE_URL}/ansible/${NETWORK_LXC_NIC_HELPER_REL}"
NETWORK_EXPORT_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_EXPORT_PLAYBOOK_REL}"
NETWORK_UPDATE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_UPDATE_PLAYBOOK_REL}"
NETWORK_VERIFY_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_VERIFY_PLAYBOOK_REL}"
NETWORK_LXC_NIC_HELPER_PATH="${PLAYBOOK_ROOT}/${NETWORK_LXC_NIC_HELPER_REL}"
NETWORK_EXTRA_VARS_PATH="${TMP_DIR}/network.update.extra-vars.yml"
ANSIBLE_VENV="/opt/ansible-venv"
ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
ANSIBLE_CORE_VERSION="${PROXMOX_BOOTSTRAP_ANSIBLE_CORE_VERSION:-2.20.5}"
ANSIBLE_CORE_SPEC="ansible-core==${ANSIBLE_CORE_VERSION}"
PROXMOX_RUNTIME_CONTEXT="host"
COMMON_HELPER_SOURCED=0

FACTS_DIR="${PROXMOX_NETWORK_FACTS_DIR:-/etc/ansible/proxmox/facts}"
ANSIBLE_PREFLIGHT_FACTS_YAML="${PROXMOX_NETWORK_PREFLIGHT_FACTS_YAML:-${FACTS_DIR}/network.preflight.latest.yml}"
ANSIBLE_PREFLIGHT_FACTS_JSON="${PROXMOX_NETWORK_PREFLIGHT_FACTS_JSON:-${FACTS_DIR}/network.preflight.latest.json}"
NETWORK_INTENT_PATH="${PROXMOX_NETWORK_INTENT_PATH:-${FACTS_DIR}/network.intent.yml}"
NETWORK_PLAN_PATH="${PROXMOX_NETWORK_PLAN_PATH:-${FACTS_DIR}/network.plan.tsv}"
NETWORK_VERIFY_PATH="${PROXMOX_NETWORK_VERIFY_PATH:-${FACTS_DIR}/network.verify.tsv}"
NETWORK_UPDATE_RUNTIME_FACTS_PATH="${PROXMOX_NETWORK_UPDATE_RUNTIME_FACTS_PATH:-${FACTS_DIR}/network.update.runtime.yml}"
NETWORK_UPDATE_STATUS_PATH="${PROXMOX_NETWORK_UPDATE_STATUS_PATH:-${FACTS_DIR}/network.update.status.yml}"
NETWORK_TRANSACTION_PATH="${PROXMOX_NETWORK_TRANSACTION_PATH:-${FACTS_DIR}/network.transaction.tsv}"
NETWORK_ROLLBACK_PATH="${PROXMOX_NETWORK_ROLLBACK_PATH:-${FACTS_DIR}/network.rollback.tsv}"
DATA_BRIDGE_SELECTION_PATH="${PROXMOX_NETWORK_DATA_BRIDGE_SELECTION_PATH:-${FACTS_DIR}/vlan.applied.yml}"
LEGACY_DATA_BRIDGE_SELECTION_PATH="${PROXMOX_NETWORK_LEGACY_DATA_BRIDGE_SELECTION_PATH:-${FACTS_DIR}/vlan.selection.yml}"
SYS_CLASS_NET_ROOT="${PROXMOX_NETWORK_SYS_CLASS_NET_ROOT:-/sys/class/net}"

RUN_DIR=""
RAW_DIR=""
RAW_HOST_DIR=""
RAW_LXC_DIR=""
RAW_VM_DIR=""
SUMMARY_PATH=""
ENV_PATH=""
HOST_YAML_PATH=""
NICS_TSV_PATH=""
BRIDGES_TSV_PATH=""
VLANS_TSV_PATH=""
LXC_TSV_PATH=""
VM_TSV_PATH=""
GUEST_RUNTIME_TSV_PATH=""
SAMBA_TSV_PATH=""
RISKS_TSV_PATH=""
SNAPSHOT_STATUS_PATH=""
SNAPSHOT_READY_PATH=""

COLLECTED_AT=""
HOSTNAME_SHORT=""
PVE_VERSION=""
KERNEL_VERSION=""
DEFAULT_ROUTE_LINE=""
DEFAULT_GATEWAY=""
DEFAULT_ROUTE_DEV=""
DISCOVERED_ADMIN_BRIDGE=""
DISCOVERED_ADMIN_NIC=""
DISCOVERED_ADMIN_NICS=""
DISCOVERED_ADMIN_IP_CIDR=""
DISCOVERED_DATA_BRIDGE=""
DISCOVERED_DATA_NICS=""
SNAPSHOT_COLLECTION_COMPLETE="false"
SNAPSHOT_READY_FOR_UPDATE="false"
SNAPSHOT_BLOCKING_CODES=""
OPEN_TTY=0
CURRENT_STAGE="startup"
PARTIAL_ERROR_PATH=""
TRACE_PATH=""
TRACE_FD_OPEN=0
PREFLIGHT_ACTIVE=0
NETWORK_RECOVERY_MODE=0
NETWORK_ROLLBACK_OUTCOME="not-run"

declare -a CT_IDS=()
declare -a VM_IDS=()
declare -a DISCOVERED_CT_IDS=()
declare -a DISCOVERED_VM_IDS=()
declare -a UPDATE_LXC_IDS=()
declare -a UPDATE_VM_IDS=()
declare -a UPDATE_PLAN_ROWS=()

usage() {
  cat <<'EOF'
Usage:
  ./setup/network.sh [preflight|update|report|all|debug]

Behavior:
  preflight  Collect host/guest network facts, classify risks, and save a
             reusable snapshot under $HOME.
  update     Build a guest network update plan from saved preflight facts and
             run Ansible check/apply for selected LXCs/VMs.
  report     Print the latest saved summary, or use PROXMOX_NETWORK_REPORT_DIR.
  all        Run preflight, then offer update stage (interactive only).
  debug      Alias for preflight with verbose trace logging enabled.

Optional environment overrides:
  PROXMOX_NETWORK_OUTPUT_ROOT=/root/proxmox.network.preflight
  PROXMOX_NETWORK_REPORT_DIR=/root/proxmox.network.preflight/host.timestamp
  PROXMOX_NETWORK_SNAPSHOT_DIR=/root/proxmox.network.preflight/host.timestamp
  PROXMOX_NETWORK_FACTS_DIR=/etc/ansible/proxmox/facts
  PROXMOX_NETWORK_EXPECTED_ADMIN_BRIDGE=<discovered-bridge>
  PROXMOX_NETWORK_EXPECTED_DATA_BRIDGE=<operator-selected-bridge>
  PROXMOX_NETWORK_MANAGEMENT_CIDR=<discovered-management-cidr>
  PROXMOX_NETWORK_DATA_CIDR=<derived-from-static-data-address>
  PROXMOX_NETWORK_MIN_DATA_SPEED_MBPS=1000
  PROXMOX_NETWORK_EXPECTED_GUEST_ADMIN_IF=<discovered-egress-if>
  PROXMOX_NETWORK_EXPECTED_GUEST_DATA_IF=<operator-selected-data-if>
  PROXMOX_NETWORK_CTIDS=100,101
  PROXMOX_NETWORK_VMIDS=200,201
  PROXMOX_NETWORK_UPDATE_MODE=check|apply
  PROXMOX_NETWORK_UPDATE_AUTO_APPLY=0|1
  PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR=<address>[/<prefix>]
  PROXMOX_NETWORK_DEFAULT_DATA_PREFIX=24
  PROXMOX_NETWORK_ALLOW_UNPROBED_DATA_IP=0|1  # carrier override only
  PROXMOX_NETWORK_ALLOW_LXC_RESTART=0|1
  PROXMOX_NETWORK_UPDATE_VLAN_TAG=<vid>   # blank means untagged
  PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS=10;20;30
  PROXMOX_NETWORK_UPDATE_VM_MODEL=virtio
  PROXMOX_NETWORK_UPDATE_LXCS=100,101
  PROXMOX_NETWORK_UPDATE_VMS=200,201
  PROXMOX_NETWORK_UPDATE_LXC_STRATEGY=add_data_nic

Safety:
  Preflight/report remain read-only. Update mode changes guest NIC config
  through Ansible with an explicit check -> apply gate. Existing egress NICs
  and default routes are preserved; the data NIC is static and has no gateway.
EOF
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is.true() {
  local value="${1:-}"
  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

source.release.common() {
  local script_dir=""
  if [[ "${COMMON_HELPER_SOURCED}" -eq 1 ]]; then
    return 0
  fi

  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  if [[ -n "${script_dir}" && -r "${script_dir}/${LOCAL_COMMON_HELPER}" ]]; then
    # shellcheck source=bootstrap/release.common.sh
    source "${script_dir}/${LOCAL_COMMON_HELPER}"
    COMMON_HELPER_SOURCED=1
    return 0
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
  # shellcheck source=/tmp/pve-feature-network/release.common.sh
  source "${COMMON_HELPER_PATH}"
  COMMON_HELPER_SOURCED=1
}

require.root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log.error "This preflight collector expects root on the Proxmox host."
    exit 1
  fi
}

require.proxmox() {
  if ! command_exists pveversion || [[ ! -d /etc/pve ]]; then
    log.error "This feature runner expects a Proxmox host."
    exit 1
  fi
}

require.valid.mode() {
  case "${FEATURE_MODE}" in
    preflight|update|report|all|debug|run) ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      log.error "Unsupported mode: ${FEATURE_MODE}"
      log.error "Use one of: preflight, update, report, all, debug"
      exit 1
      ;;
  esac
}

require.commands() {
  local missing=0
  local cmd=""
  for cmd in arping awk bash bridge date grep hostname ip pct pvesh qm sed uname; do
    if ! command_exists "${cmd}"; then
      log.error "Missing required command: ${cmd}"
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

require.update.commands() {
  local missing=0
  local cmd=""
  for cmd in arping awk bash grep ip pct python3 qm sed sort wget; do
    if ! command_exists "${cmd}"; then
      log.error "Missing required update command: ${cmd}"
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

sanitize.field() {
  printf '%s' "${1:-}" | tr '\t\r\n' '   '
}

yaml.quote() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

open.tty() {
  if [[ ! -r /dev/tty ]]; then
    return 1
  fi
  exec 3<>/dev/tty
  OPEN_TTY=1
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

trim.space() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

valid.ipv4.cidr() {
  local value="${1:-}" address prefix octet
  [[ "${value}" == */* ]] || return 1
  address="${value%/*}"
  prefix="${value#*/}"
  [[ "${prefix}" =~ ^[0-9]+$ ]] && ((prefix >= 1 && prefix <= 32)) || return 1
  IFS='.' read -r -a octets <<< "${address}"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] && ((10#${octet} >= 0 && 10#${octet} <= 255)) || return 1
  done
}

normalize.ipv4.interface.cidr() {
  local value="${1:-}" default_prefix="${2:-${PROXMOX_NETWORK_DEFAULT_DATA_PREFIX}}"
  python3 -E - "${value}" "${default_prefix}" <<'PY'
import ipaddress
import sys

value = sys.argv[1].strip()
default_prefix = sys.argv[2].strip()
try:
    prefix = int(default_prefix)
except ValueError:
    raise SystemExit(1)
if prefix < 1 or prefix > 30:
    raise SystemExit(1)
if "/" not in value:
    value = f"{value}/{prefix}"
try:
    interface = ipaddress.ip_interface(value)
except ValueError:
    raise SystemExit(1)
if not isinstance(interface, ipaddress.IPv4Interface):
    raise SystemExit(1)
network = interface.network
if network.prefixlen < 1 or network.prefixlen > 30:
    raise SystemExit(1)
if interface.ip in (network.network_address, network.broadcast_address):
    raise SystemExit(1)
print(f"{interface.ip}/{network.prefixlen}")
PY
}

valid.interface.name() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]]
}

tsv.data.row.count() {
  local path="${1:-}"
  [[ -f "${path}" ]] || return 1
  awk 'NR > 1 {count += 1} END {print count + 0}' "${path}"
}

tsv.require.header() {
  local path="${1:-}" expected="${2:-}" actual=""
  [[ -f "${path}" ]] || return 1
  IFS= read -r actual < "${path}" || true
  [[ "${actual}" == "${expected}" ]]
}

tsv.validate.schema() {
  local path="${1:-}" expected_header="${2:-}" expected_fields="${3:-0}"
  tsv.require.header "${path}" "${expected_header}" || return 1
  awk -F'\t' -v fields="${expected_fields}" 'NR > 1 && NF != fields {exit 1}' "${path}"
}

append.blocking.code() {
  local code="${1:-}"
  [[ -n "${code}" ]] || return 0
  case ",${SNAPSHOT_BLOCKING_CODES}," in
    *",${code},"*) return 0 ;;
  esac
  if [[ -n "${SNAPSHOT_BLOCKING_CODES}" ]]; then
    SNAPSHOT_BLOCKING_CODES+=","
  fi
  SNAPSHOT_BLOCKING_CODES+="${code}"
}

derive.ipv4.network.cidr() {
  local value="${1:-}"
  python3 -E - "${value}" <<'PY'
import ipaddress
import sys

print(ipaddress.ip_interface(sys.argv[1]).network)
PY
}

ipv4.cidrs.overlap() {
  local left="${1:-}" right="${2:-}"
  python3 -E - "${left}" "${right}" <<'PY'
import ipaddress
import sys

left = ipaddress.ip_network(sys.argv[1], strict=False)
right = ipaddress.ip_network(sys.argv[2], strict=False)
raise SystemExit(0 if left.overlaps(right) else 1)
PY
}

physical.nic.speed.evidence.mbps() {
  local iface="${1:-}" driver="${2:-}" current_speed="${3:-}" supported_speed="" evidence=0
  if [[ "${current_speed}" =~ ^[0-9]+$ ]] && ((current_speed > evidence)); then
    evidence="${current_speed}"
  fi
  if command_exists ethtool && [[ -n "${iface}" ]]; then
    supported_speed="$(
      ethtool "${iface}" 2>/dev/null \
        | awk '
            /Supported link modes:/ { supported=1 }
            /Advertised link modes:/ { supported=0 }
            supported {
              for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+base/) {
                  split($i, value, "base")
                  if ((value[1] + 0) > max) max = value[1] + 0
                }
              }
            }
            END { print max + 0 }
          '
    )"
    if [[ "${supported_speed}" =~ ^[0-9]+$ ]] && ((supported_speed > evidence)); then
      evidence="${supported_speed}"
    fi
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

probe.data.ip.conflict() {
  local address carrier
  address="${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR%/*}"
  carrier="$(cat "${SYS_CLASS_NET_ROOT}/${EXPECTED_DATA_BRIDGE}/carrier" 2>/dev/null || true)"
  if [[ "${carrier}" != "1" ]]; then
    if is.true "${PROXMOX_NETWORK_ALLOW_UNPROBED_DATA_IP}"; then
      log.warn "Data bridge ${EXPECTED_DATA_BRIDGE} has no carrier; explicit override skips duplicate-address probing for ${address}."
      return 0
    fi
    log.error "Data bridge ${EXPECTED_DATA_BRIDGE} has no carrier; refusing an unverifiable static address."
    log.error "Connect the data link or explicitly set PROXMOX_NETWORK_ALLOW_UNPROBED_DATA_IP=1."
    return 1
  fi
  if ! command_exists arping; then
    log.error 'arping is a required Proxmox baseline dependency (package: iputils-arping).'
    return 1
  fi
  log "Probing ${address} for duplicates on ${EXPECTED_DATA_BRIDGE}."
  if ! arping -D -q -c 3 -w 4 -I "${EXPECTED_DATA_BRIDGE}" "${address}"; then
    log.error "Static address ${address} answered on ${EXPECTED_DATA_BRIDGE}; choose an unused address."
    return 1
  fi
  log "No duplicate response detected for ${address}."
}

path.basename.or.empty() {
  local path="${1:-}"
  if [[ -z "${path}" ]]; then
    printf ''
    return 0
  fi
  basename "${path}" 2>/dev/null || true
}

readlink.basename.or.empty() {
  local path="${1:-}"
  local resolved=""
  resolved="$(readlink -f "${path}" 2>/dev/null || true)"
  path.basename.or.empty "${resolved}"
}

set.stage() {
  CURRENT_STAGE="$1"
  log "Stage: ${CURRENT_STAGE}"
}

enable.debug.trace() {
  if ! is.true "${FEATURE_DEBUG}"; then
    return 0
  fi
  exec 9>>"${TRACE_PATH}"
  TRACE_FD_OPEN=1
  export BASH_XTRACEFD=9
  export PS4='+ [network:${LINENO}:${FUNCNAME[0]:-main}] '
  set -x
  log "Debug tracing enabled: ${TRACE_PATH}"
}

join.discovered.ids() {
  local -n ids_ref="$1"
  local joined=""
  if ((${#ids_ref[@]} == 0)); then
    printf 'none'
    return 0
  fi
  joined="$(join.by ',' "${ids_ref[@]}")"
  printf '%s' "${joined}"
}

write.partial.error() {
  local line_no="${1:-unknown}"
  local exit_code="${2:-1}"
  if [[ -z "${RUN_DIR}" ]]; then
    return 0
  fi
  PARTIAL_ERROR_PATH="${RUN_DIR}/network.error.txt"
  {
    printf 'setup/network.sh error\n'
    printf 'host: %s\n' "${HOSTNAME_SHORT:-unknown}"
    printf 'stage: %s\n' "${CURRENT_STAGE:-unknown}"
    printf 'line: %s\n' "${line_no}"
    printf 'exit_code: %s\n' "${exit_code}"
    printf 'collected_at: %s\n' "${COLLECTED_AT:-unknown}"
    printf 'run_dir: %s\n' "${RUN_DIR}"
  } > "${PARTIAL_ERROR_PATH}"
}

on.err() {
  local line_no="${1:-unknown}"
  local exit_code="${2:-1}"
  if [[ "${PREFLIGHT_ACTIVE}" -eq 1 && -n "${RUN_DIR}" ]]; then
    write.partial.error "${line_no}" "${exit_code}"
    SNAPSHOT_COLLECTION_COMPLETE="false"
    SNAPSHOT_READY_FOR_UPDATE="false"
    append.blocking.code "collection_failed"
    write.snapshot.status || true
    update.latest.report.pointer || true
  fi
  log.error "Network workflow failed at stage=${CURRENT_STAGE} line=${line_no} exit=${exit_code}"
  if [[ -n "${PARTIAL_ERROR_PATH}" ]]; then
    log.error "Partial error details saved to ${PARTIAL_ERROR_PATH}"
  fi
  exit "${exit_code}"
}

on.exit() {
  local exit_code="${1:-0}"
  if [[ "${TRACE_FD_OPEN}" -eq 1 ]]; then
    set +x || true
    exec 9>&- || true
  fi
  if [[ "${OPEN_TTY}" -eq 1 ]]; then
    exec 3>&- 3<&- || true
  fi
  if [[ "${exit_code}" -ne 0 && "${PREFLIGHT_ACTIVE}" -eq 1 && -n "${RUN_DIR}" && -n "${PARTIAL_ERROR_PATH}" && ! -f "${PARTIAL_ERROR_PATH}" ]]; then
    write.partial.error "exit" "${exit_code}"
  fi
}

install.runtime.traps() {
  trap 'on.err "${LINENO}" "$?"' ERR
  trap 'on.exit "$?"' EXIT
}

first_line() {
  awk 'NF && $0 !~ /^#/ { print; exit }' "$1" 2>/dev/null || true
}

extract.csv.kv() {
  local body="${1:-}"
  local key="${2:-}"
  local entry=""
  IFS=',' read -r -a __entries <<< "${body}"
  for entry in "${__entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    if [[ "${entry}" == "${key}="* ]]; then
      printf '%s' "${entry#*=}"
      return 0
    fi
  done
  return 1
}

drop.csv.kv() {
  local body="${1:-}"
  local key="${2:-}"
  local entry=""
  local first=1
  local output=""
  IFS=',' read -r -a __entries <<< "${body}"
  for entry in "${__entries[@]}"; do
    entry="$(trim.space "${entry}")"
    [[ -n "${entry}" ]] || continue
    if [[ "${entry}" == "${key}="* ]]; then
      continue
    fi
    if [[ "${first}" -eq 0 ]]; then
      output+=","
    fi
    output+="${entry}"
    first=0
  done
  printf '%s' "${output}"
}

upsert.csv.kv() {
  local body="${1:-}"
  local key="${2:-}"
  local value="${3:-}"
  local output=""
  output="$(drop.csv.kv "${body}" "${key}")"
  if [[ -n "${value}" ]]; then
    if [[ -n "${output}" ]]; then
      output+=","
    fi
    output+="${key}=${value}"
  fi
  printf '%s' "${output}"
}

append.tsv.row() {
  local path="$1"
  shift
  local first=1
  local value=""
  for value in "$@"; do
    if [[ "${first}" -eq 0 ]]; then
      printf '\t' >> "${path}"
    fi
    sanitize.field "${value}" >> "${path}"
    first=0
  done
  printf '\n' >> "${path}"
}

capture.cmd() {
  local output_path="$1"
  local description="$2"
  local command_string="$3"
  {
    printf '# %s\n' "${description}"
    printf '# cmd: %s\n\n' "${command_string}"
    bash -lc "${command_string}"
  } > "${output_path}" 2>&1 || true
}

parse.id.filter() {
  local raw="${1:-}"
  local cleaned=""
  local token=""
  if [[ -z "${raw}" ]]; then
    return 0
  fi
  cleaned="$(printf '%s' "${raw}" | tr ',;' '  ')"
  for token in ${cleaned}; do
    if [[ "${token}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${token}"
    fi
  done
}

join.by() {
  local delimiter="${1:-,}"
  shift || true
  local first=1
  local value=""
  for value in "$@"; do
    [[ -n "${value}" ]] || continue
    if [[ "${first}" -eq 0 ]]; then
      printf '%s' "${delimiter}"
    fi
    printf '%s' "${value}"
    first=0
  done
}

append.unique.id() {
  local -n id_ref="$1"
  local candidate="${2:-}"
  local existing=""
  [[ -n "${candidate}" ]] || return 0
  for existing in "${id_ref[@]}"; do
    if [[ "${existing}" == "${candidate}" ]]; then
      return 0
    fi
  done
  id_ref+=("${candidate}")
}

csv.from.id.list() {
  local -n id_ref="$1"
  if ((${#id_ref[@]} == 0)); then
    printf ''
    return 0
  fi
  join.by ',' "${id_ref[@]}"
}

init.run.dir() {
  HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
  COLLECTED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  local stamp=""
  stamp="$(date '+%Y%m%d.%H%M%S')"

  RUN_DIR="${OUTPUT_ROOT}/${HOSTNAME_SHORT}.${stamp}"
  set.run.paths.from.dir
  mkdir -p "${RAW_HOST_DIR}" "${RAW_LXC_DIR}" "${RAW_VM_DIR}"
}

set.run.paths.from.dir() {
  [[ -n "${RUN_DIR}" ]] || return 1
  RAW_DIR="${RUN_DIR}/raw"
  RAW_HOST_DIR="${RAW_DIR}/host"
  RAW_LXC_DIR="${RAW_DIR}/lxc"
  RAW_VM_DIR="${RAW_DIR}/vm"

  SUMMARY_PATH="${RUN_DIR}/network.summary.txt"
  ENV_PATH="${RUN_DIR}/network.next-stage.env"
  HOST_YAML_PATH="${RUN_DIR}/network.host.yml"
  NICS_TSV_PATH="${RUN_DIR}/network.nics.tsv"
  BRIDGES_TSV_PATH="${RUN_DIR}/network.bridges.tsv"
  VLANS_TSV_PATH="${RUN_DIR}/network.vlans.tsv"
  LXC_TSV_PATH="${RUN_DIR}/network.lxc.tsv"
  VM_TSV_PATH="${RUN_DIR}/network.vm.tsv"
  GUEST_RUNTIME_TSV_PATH="${RUN_DIR}/network.guest.runtime.tsv"
  SAMBA_TSV_PATH="${RUN_DIR}/network.samba.tsv"
  RISKS_TSV_PATH="${RUN_DIR}/network.risks.tsv"
  SNAPSHOT_STATUS_PATH="${RUN_DIR}/network.snapshot.status.yml"
  SNAPSHOT_READY_PATH="${RUN_DIR}/network.snapshot.ready"
  TRACE_PATH="${RUN_DIR}/network.trace.log"
}

update.latest.report.pointer() {
  mkdir -p "${OUTPUT_ROOT}"
  ln -sfn "${RUN_DIR}" "${OUTPUT_ROOT}/latest-report"
  ln -sfn "${RUN_DIR}" "${OUTPUT_ROOT}/latest"
  printf '%s\n' "${RUN_DIR}" > "${OUTPUT_ROOT}/latest.path"
}

update.latest.ready.pointer() {
  mkdir -p "${OUTPUT_ROOT}"
  ln -sfn "${RUN_DIR}" "${OUTPUT_ROOT}/latest-ready"
  printf '%s\n' "${RUN_DIR}" > "${OUTPUT_ROOT}/latest-ready.path"
}

discover.basic.host.facts() {
  local candidate_bridge="" candidate_count=0 port_path=""
  local -a admin_physical_nics=()
  set.stage "discover.basic.host.facts"
  if [[ -z "${HOSTNAME_SHORT}" ]]; then
    HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
  fi
  PVE_VERSION="$(pveversion 2>/dev/null | head -n1 || true)"
  KERNEL_VERSION="$(uname -r 2>/dev/null || true)"
  DEFAULT_ROUTE_LINE="$(ip route show default 2>/dev/null | head -n1 || true)"
  DEFAULT_GATEWAY="$(awk '/^default / {for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}' <<< "${DEFAULT_ROUTE_LINE}")"
  DEFAULT_ROUTE_DEV="$(awk '/^default / {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "${DEFAULT_ROUTE_LINE}")"

  DISCOVERED_ADMIN_BRIDGE="${DEFAULT_ROUTE_DEV}"
  DISCOVERED_ADMIN_NIC=""
  DISCOVERED_ADMIN_NICS=""
  if [[ -n "${DEFAULT_ROUTE_DEV}" && -L "${SYS_CLASS_NET_ROOT}/${DEFAULT_ROUTE_DEV}/master" ]]; then
    DISCOVERED_ADMIN_BRIDGE="$(readlink.basename.or.empty "${SYS_CLASS_NET_ROOT}/${DEFAULT_ROUTE_DEV}/master")"
  fi
  if [[ -n "${DISCOVERED_ADMIN_BRIDGE}" && -d "${SYS_CLASS_NET_ROOT}/${DISCOVERED_ADMIN_BRIDGE}/brif" ]]; then
    for port_path in "${SYS_CLASS_NET_ROOT}/${DISCOVERED_ADMIN_BRIDGE}"/brif/*; do
      [[ -e "${port_path}" ]] || continue
      if [[ -e "${SYS_CLASS_NET_ROOT}/$(basename "${port_path}")/device" ]]; then
        admin_physical_nics+=("$(basename "${port_path}")")
      fi
    done
  elif [[ -n "${DEFAULT_ROUTE_DEV}" && -e "${SYS_CLASS_NET_ROOT}/${DEFAULT_ROUTE_DEV}/device" ]]; then
    admin_physical_nics+=("${DEFAULT_ROUTE_DEV}")
  fi
  if ((${#admin_physical_nics[@]} > 0)); then
    DISCOVERED_ADMIN_NIC="${admin_physical_nics[0]}"
    DISCOVERED_ADMIN_NICS="$(join.by ',' "${admin_physical_nics[@]}")"
  fi
  DISCOVERED_ADMIN_IP_CIDR="$(ip -o -4 addr show dev "${DISCOVERED_ADMIN_BRIDGE}" 2>/dev/null | awk '{print $4}' | paste -sd, -)"

  if [[ ! -r "${DATA_BRIDGE_SELECTION_PATH}" && -r "${LEGACY_DATA_BRIDGE_SELECTION_PATH}" ]]; then
    local legacy_bridge=""
    legacy_bridge="$(
      awk '
        /^[[:space:]]{2}data:[[:space:]]*$/ { in_data=1; next }
        in_data && /^[[:space:]]{4}bridge:[[:space:]]*/ {
          value=$0
          sub(/^[^:]+:[[:space:]]*/, "", value)
          gsub(/["'\'' ]/, "", value)
          print value
          exit
        }
        in_data && /^[[:space:]]{2}[^[:space:]]/ { in_data=0 }
      ' "${LEGACY_DATA_BRIDGE_SELECTION_PATH}"
    )"
    if [[ -n "${legacy_bridge}" && -d "${SYS_CLASS_NET_ROOT}/${legacy_bridge}/bridge" ]]; then
      DATA_BRIDGE_SELECTION_PATH="${LEGACY_DATA_BRIDGE_SELECTION_PATH}"
      log.warn "Using a legacy selection because its data bridge is live; rerun setup.vlan.sh apply to migrate state."
    fi
  fi

  if [[ -z "${EXPECTED_ADMIN_BRIDGE}" ]]; then
    EXPECTED_ADMIN_BRIDGE="${DISCOVERED_ADMIN_BRIDGE}"
  fi
  if [[ -z "${EXPECTED_MANAGEMENT_CIDR}" ]]; then
    EXPECTED_MANAGEMENT_CIDR="$(ip -4 route show dev "${DISCOVERED_ADMIN_BRIDGE}" proto kernel scope link 2>/dev/null | awk 'NR==1 {print $1}')"
  fi

  if [[ -z "${EXPECTED_DATA_BRIDGE}" && -r "${DATA_BRIDGE_SELECTION_PATH}" ]]; then
    EXPECTED_DATA_BRIDGE="$(
      awk '
        /^[[:space:]]{2}data:[[:space:]]*$/ { in_data=1; next }
        in_data && /^[[:space:]]{4}bridge:[[:space:]]*/ {
          value=$0
          sub(/^[^:]+:[[:space:]]*/, "", value)
          gsub(/["'\'' ]/, "", value)
          print value
          exit
        }
        in_data && /^[[:space:]]{2}[^[:space:]]/ { in_data=0 }
      ' "${DATA_BRIDGE_SELECTION_PATH}"
    )"
  fi
  if [[ -z "${EXPECTED_DATA_LINK_MODE}" && -r "${DATA_BRIDGE_SELECTION_PATH}" ]]; then
    EXPECTED_DATA_LINK_MODE="$(
      awk '
        /^[[:space:]]{2}data:[[:space:]]*$/ { in_data=1; next }
        in_data && /^[[:space:]]{4}link_mode:[[:space:]]*/ {
          value=$0
          sub(/^[^:]+:[[:space:]]*/, "", value)
          gsub(/["'\'' ]/, "", value)
          print value
          exit
        }
        in_data && /^[[:space:]]{2}[^[:space:]]/ { in_data=0 }
      ' "${DATA_BRIDGE_SELECTION_PATH}"
    )"
  fi

  if [[ -z "${EXPECTED_DATA_BRIDGE}" ]]; then
    for candidate_path in "${SYS_CLASS_NET_ROOT}"/*/bridge; do
      [[ -d "${candidate_path}" ]] || continue
      candidate_bridge="$(basename "$(dirname "${candidate_path}")")"
      [[ "${candidate_bridge}" != "${DISCOVERED_ADMIN_BRIDGE}" ]] || continue
      for port_path in "${SYS_CLASS_NET_ROOT}/${candidate_bridge}"/brif/*; do
        [[ -e "${port_path}" ]] || continue
        if [[ -e "${SYS_CLASS_NET_ROOT}/$(basename "${port_path}")/device" ]]; then
          DISCOVERED_DATA_BRIDGE="${candidate_bridge}"
          candidate_count=$((candidate_count + 1))
          break
        fi
      done
    done
    if ((candidate_count == 1)); then
      EXPECTED_DATA_BRIDGE="${DISCOVERED_DATA_BRIDGE}"
    else
      DISCOVERED_DATA_BRIDGE=""
    fi
  elif [[ -d "${SYS_CLASS_NET_ROOT}/${EXPECTED_DATA_BRIDGE}/bridge" ]] \
    && ip link show dev "${EXPECTED_DATA_BRIDGE}" >/dev/null 2>&1; then
    DISCOVERED_DATA_BRIDGE="${EXPECTED_DATA_BRIDGE}"
  else
    DISCOVERED_DATA_BRIDGE=""
  fi
  log "Discovered admin route_dev=${DEFAULT_ROUTE_DEV:-unknown} bridge=${DISCOVERED_ADMIN_BRIDGE:-unknown} physical_nics=${DISCOVERED_ADMIN_NICS:-none} admin_ip=${DISCOVERED_ADMIN_IP_CIDR:-none} gateway=${DEFAULT_GATEWAY:-none}"
  log "Selected data bridge=${EXPECTED_DATA_BRIDGE:-operator-selection-required} live_data_bridge=${DISCOVERED_DATA_BRIDGE:-missing} link_mode=${EXPECTED_DATA_LINK_MODE:-unknown} management_cidr=${EXPECTED_MANAGEMENT_CIDR:-unknown}"
}

collect.host.raw() {
  set.stage "collect.host.raw"
  capture.cmd "${RAW_HOST_DIR}/pveversion.txt" "Proxmox version" "pveversion"
  capture.cmd "${RAW_HOST_DIR}/uname.txt" "Kernel version" "uname -a"
  capture.cmd "${RAW_HOST_DIR}/ip.br.link.txt" "Interface link summary" "ip -br link"
  capture.cmd "${RAW_HOST_DIR}/ip.br.addr.txt" "Interface address summary" "ip -br addr"
  capture.cmd "${RAW_HOST_DIR}/ip.route.txt" "Route table" "ip route"
  capture.cmd "${RAW_HOST_DIR}/ip.rule.txt" "Policy routing rules" "ip rule"
  capture.cmd "${RAW_HOST_DIR}/bridge.link.txt" "Bridge membership" "bridge link show"
  capture.cmd "${RAW_HOST_DIR}/bridge.vlan.txt" "Bridge VLAN view" "bridge vlan show"
  capture.cmd "${RAW_HOST_DIR}/pvesh.network.yaml" "Proxmox network API" "pvesh get /nodes/\$(hostname)/network --output-format yaml"
  capture.cmd "${RAW_HOST_DIR}/pvesh.status.json" "Proxmox status API" "pvesh get /nodes/\$(hostname)/status"
  capture.cmd "${RAW_HOST_DIR}/pct.list.txt" "LXC inventory" "pct list"
  capture.cmd "${RAW_HOST_DIR}/qm.list.txt" "VM inventory" "qm list"
  capture.cmd "${RAW_HOST_DIR}/interfaces.txt" "Host interfaces file" "cat /etc/network/interfaces"
  capture.cmd "${RAW_HOST_DIR}/interfaces.d.list.txt" "Host interfaces.d inventory" "find /etc/network/interfaces.d -maxdepth 1 -type f 2>/dev/null | sort"

  local path=""
  for path in /etc/network/interfaces.d/*; do
    [[ -f "${path}" ]] || continue
    capture.cmd "${RAW_HOST_DIR}/interfaces.d.$(basename "${path}").txt" "Host interfaces.d file ${path}" "cat $(printf '%q' "${path}")"
  done
  log "Captured raw host facts in ${RAW_HOST_DIR}"
}

collect.nics.tsv() {
  set.stage "collect.nics.tsv"
  printf 'iface\tkind\tmac\tmtu\toperstate\tcarrier\tspeed\tduplex\tdriver\tpci_slot\tmaster\tipv4\tipv6\n' > "${NICS_TSV_PATH}"

  local iface_path=""
  local iface=""
  local kind=""
  local mac=""
  local mtu=""
  local operstate=""
  local carrier=""
  local speed=""
  local duplex=""
  local driver=""
  local pci_slot=""
  local master=""
  local ipv4=""
  local ipv6=""
  local collected_count=""
  local physical_data_nics=()
  local physical_admin_nics=()

  for iface_path in "${SYS_CLASS_NET_ROOT}"/*; do
    [[ -d "${iface_path}" ]] || continue

    iface="$(basename "${iface_path}")"
    [[ -n "${iface}" ]] || continue
    if ! ip link show dev "${iface}" >/dev/null 2>&1; then
      log.warn "Skipping non-runtime network entry: ${iface}"
      continue
    fi

    if [[ "${iface}" == "lo" ]]; then
      kind="loopback"
    elif [[ -d "${SYS_CLASS_NET_ROOT}/${iface}/bridge" ]]; then
      kind="bridge"
    elif [[ -e "${SYS_CLASS_NET_ROOT}/${iface}/device" ]]; then
      kind="physical"
    else
      kind="virtual"
    fi

    mac="$(cat "${SYS_CLASS_NET_ROOT}/${iface}/address" 2>/dev/null || true)"
    mtu="$(cat "${SYS_CLASS_NET_ROOT}/${iface}/mtu" 2>/dev/null || true)"
    operstate="$(cat "${SYS_CLASS_NET_ROOT}/${iface}/operstate" 2>/dev/null || true)"
    carrier="$(cat "${SYS_CLASS_NET_ROOT}/${iface}/carrier" 2>/dev/null || true)"
    speed="$(cat "${SYS_CLASS_NET_ROOT}/${iface}/speed" 2>/dev/null || true)"
    duplex="$(cat "${SYS_CLASS_NET_ROOT}/${iface}/duplex" 2>/dev/null || true)"
    driver="$(readlink.basename.or.empty "${SYS_CLASS_NET_ROOT}/${iface}/device/driver")"
    pci_slot="$(readlink.basename.or.empty "${SYS_CLASS_NET_ROOT}/${iface}/device")"
    master=""
    if [[ -L "${SYS_CLASS_NET_ROOT}/${iface}/master" ]]; then
      master="$(readlink.basename.or.empty "${SYS_CLASS_NET_ROOT}/${iface}/master")"
    fi
    ipv4="$(ip -o -4 addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | paste -sd, - || true)"
    ipv6="$(ip -o -6 addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | paste -sd, - || true)"

    append.tsv.row "${NICS_TSV_PATH}" \
      "${iface}" "${kind}" "${mac}" "${mtu}" "${operstate}" "${carrier}" \
      "${speed}" "${duplex}" "${driver}" "${pci_slot}" "${master}" "${ipv4}" "${ipv6}"

    if command_exists ethtool; then
      capture.cmd "${RAW_HOST_DIR}/ethtool.${iface}.txt" "ethtool ${iface}" "ethtool $(printf '%q' "${iface}")"
      capture.cmd "${RAW_HOST_DIR}/ethtool.i.${iface}.txt" "ethtool -i ${iface}" "ethtool -i $(printf '%q' "${iface}")"
    fi

    if [[ -z "${DISCOVERED_ADMIN_NIC}" && "${iface}" == "${DEFAULT_ROUTE_DEV}" ]]; then
      DISCOVERED_ADMIN_NIC="${iface}"
    fi

    if [[ "${master}" == "${EXPECTED_DATA_BRIDGE}" && "${kind}" == "physical" ]]; then
      physical_data_nics+=("${iface}")
    fi
    if [[ "${master}" == "${DISCOVERED_ADMIN_BRIDGE}" && "${kind}" == "physical" ]]; then
      physical_admin_nics+=("${iface}")
    fi
  done

  if [[ -z "${DISCOVERED_ADMIN_NIC}" && "${#physical_admin_nics[@]}" -gt 0 ]]; then
    DISCOVERED_ADMIN_NIC="${physical_admin_nics[0]}"
  fi
  if [[ -z "${DISCOVERED_ADMIN_NICS}" && "${#physical_admin_nics[@]}" -gt 0 ]]; then
    DISCOVERED_ADMIN_NICS="$(join.by ',' "${physical_admin_nics[@]}")"
  fi
  DISCOVERED_DATA_NICS="$(join.by ',' "${physical_data_nics[@]}")"
  collected_count="$(tsv.data.row.count "${NICS_TSV_PATH}")"
  log "Collected NIC facts: ${collected_count} interfaces; data_nics=${DISCOVERED_DATA_NICS:-none}"
}

collect.bridges.tsv() {
  set.stage "collect.bridges.tsv"
  printf 'bridge\tvlan_filtering\tmembers\tipv4\tipv6\n' > "${BRIDGES_TSV_PATH}"

  local iface=""
  local vlan_filtering=""
  local members=""
  local ipv4=""
  local ipv6=""
  local collected_count=""

  for iface in "${SYS_CLASS_NET_ROOT}"/*; do
    iface="$(basename "${iface}")"
    [[ -d "${SYS_CLASS_NET_ROOT}/${iface}/bridge" ]] || continue

    vlan_filtering="$(cat "${SYS_CLASS_NET_ROOT}/${iface}/bridge/vlan_filtering" 2>/dev/null || true)"
    members="$(bridge link show master "${iface}" 2>/dev/null | sed -n 's/^[0-9]\+: \([^:@[:space:]]*\).*/\1/p' | paste -sd, -)"
    ipv4="$(ip -o -4 addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | paste -sd, -)"
    ipv6="$(ip -o -6 addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | paste -sd, -)"

    append.tsv.row "${BRIDGES_TSV_PATH}" "${iface}" "${vlan_filtering}" "${members}" "${ipv4}" "${ipv6}"
  done
  collected_count="$(tsv.data.row.count "${BRIDGES_TSV_PATH}")"
  log "Collected bridge facts: ${collected_count} bridge rows"
}

collect.vlans.tsv() {
  set.stage "collect.vlans.tsv"
  printf 'port\tvlan_detail\n' > "${VLANS_TSV_PATH}"
  awk '
    /^#/ || /^$/ { next }
    /^[^[:space:]]/ {
      port = $1
      sub(/^[^[:space:]]+[[:space:]]+/, "", $0)
      print port "\t" $0
      next
    }
    {
      gsub(/^[[:space:]]+/, "", $0)
      if (port != "" && $0 != "") {
        print port "\t" $0
      }
    }
  ' "${RAW_HOST_DIR}/bridge.vlan.txt" >> "${VLANS_TSV_PATH}" 2>/dev/null || true
  log "Collected VLAN membership facts"
}

discover.available.ct.ids() {
  DISCOVERED_CT_IDS=()
  local token=""
  while IFS= read -r token; do
    [[ -n "${token}" ]] && DISCOVERED_CT_IDS+=("${token}")
  done < <(pct list 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+$/ {print $1}')
}

discover.available.vm.ids() {
  DISCOVERED_VM_IDS=()
  local token=""
  while IFS= read -r token; do
    [[ -n "${token}" ]] && DISCOVERED_VM_IDS+=("${token}")
  done < <(qm list 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+$/ {print $1}')
}

collect.guest.raw() {
  set.stage "collect.guest.raw"
  local id=""
  for id in "${CT_IDS[@]}"; do
    mkdir -p "${RAW_LXC_DIR}/${id}"
    capture.cmd "${RAW_LXC_DIR}/${id}/status.txt" "pct status ${id}" "pct status ${id}"
    capture.cmd "${RAW_LXC_DIR}/${id}/config.txt" "pct config ${id}" "pct config ${id}"
    capture.cmd "${RAW_LXC_DIR}/${id}/host.plumbing.txt" "Host-side CT plumbing ${id}" \
      "ip link show | grep -E 'fwpr${id}p|fwln${id}i|veth${id}i' || true"
  done
  for id in "${VM_IDS[@]}"; do
    mkdir -p "${RAW_VM_DIR}/${id}"
    capture.cmd "${RAW_VM_DIR}/${id}/status.txt" "qm status ${id}" "qm status ${id}"
    capture.cmd "${RAW_VM_DIR}/${id}/config.txt" "qm config ${id}" "qm config ${id}"
  done
  log "Captured raw guest facts for LXC IDs=$(join.by ',' "${CT_IDS[@]}") VM IDs=$(join.by ',' "${VM_IDS[@]}")"
}

discover.ct.ids() {
  CT_IDS=()
  local token=""
  if [[ -n "${CTID_FILTER}" ]]; then
    while IFS= read -r token; do
      [[ -n "${token}" ]] && CT_IDS+=("${token}")
    done < <(parse.id.filter "${CTID_FILTER}")
    return
  fi

  CT_IDS=("${DISCOVERED_CT_IDS[@]}")
}

discover.vm.ids() {
  VM_IDS=()
  local token=""
  if [[ -n "${VMID_FILTER}" ]]; then
    while IFS= read -r token; do
      [[ -n "${token}" ]] && VM_IDS+=("${token}")
    done < <(parse.id.filter "${VMID_FILTER}")
    return
  fi

  VM_IDS=("${DISCOVERED_VM_IDS[@]}")
}

append.risk() {
  append.tsv.row "${RISKS_TSV_PATH}" "$@"
}

collect.lxc.data() {
  set.stage "collect.lxc.data"
  printf 'guest_type\tguest_id\tguest_name\tstatus\tnet_slot\tguest_if\tbridge\tvlan_tag\ttrunks\tfirewall\tmtu\tip_hint\tgw_hint\traw\n' > "${LXC_TSV_PATH}"

  local id=""
  local collected_count=""
  local status=""
  local conf_path=""
  local runtime_dir=""
  local name=""
  local line=""
  local slot=""
  local body=""
  local guest_if=""
  local bridge_name=""
  local vlan_tag=""
  local trunks=""
  local firewall=""
  local mtu=""
  local ip_hint=""
  local gw_hint=""
  local has_admin_nic=0
  local has_data_nic=0
  local data_nic_name=""
  local admin_nic_name=""
  local runtime_iface_summary=""
  local runtime_default_route=""
  local listen_summary=""
  local sysctl_summary=""
  local guest_sysctl_keys=""
  local testparm_interfaces=""
  local testparm_bind_only=""
  local testparm_hosts_allow=""
  local testparm_smb_ports=""
  local ufw_summary=""
  local service_present="no"

  printf 'guest_type\tguest_id\tguest_name\tstatus\truntime_source\tipv4_interfaces\tdefault_route\tlisten_summary\tsysctl_summary\n' > "${GUEST_RUNTIME_TSV_PATH}"
  printf 'guest_type\tguest_id\tguest_name\tstatus\tservice_present\tinterfaces\tbind_interfaces_only\thosts_allow\tsmb_ports\tufw_summary\n' > "${SAMBA_TSV_PATH}"

  for id in "${CT_IDS[@]}"; do
    log "Inspecting LXC ${id}"
    status="$(pct status "${id}" 2>/dev/null | awk '{print $2}' || true)"
    runtime_dir="${RAW_LXC_DIR}/${id}"
    mkdir -p "${runtime_dir}"

    capture.cmd "${runtime_dir}/config.txt" "pct config ${id}" "pct config ${id}"
    conf_path="${runtime_dir}/config.txt"
    name="$(awk -F': ' '/^hostname:/ {print $2; exit}' "${conf_path}" 2>/dev/null || true)"
    [[ -n "${name}" ]] || name="ct${id}"

    has_admin_nic=0
    has_data_nic=0
    data_nic_name=""
    admin_nic_name=""

    while IFS= read -r line; do
      slot="${line%%:*}"
      body="${line#*: }"
      guest_if="$(extract.csv.kv "${body}" "name" || true)"
      bridge_name="$(extract.csv.kv "${body}" "bridge" || true)"
      vlan_tag="$(extract.csv.kv "${body}" "tag" || true)"
      trunks="$(extract.csv.kv "${body}" "trunks" || true)"
      firewall="$(extract.csv.kv "${body}" "firewall" || true)"
      mtu="$(extract.csv.kv "${body}" "mtu" || true)"
      ip_hint="$(extract.csv.kv "${body}" "ip" || true)"
      gw_hint="$(extract.csv.kv "${body}" "gw" || true)"

      [[ -n "${guest_if}" ]] || guest_if="-"
      [[ -n "${bridge_name}" ]] || bridge_name="-"
      [[ -n "${vlan_tag}" ]] || vlan_tag="-"
      [[ -n "${trunks}" ]] || trunks="-"
      [[ -n "${firewall}" ]] || firewall="-"
      [[ -n "${mtu}" ]] || mtu="-"
      [[ -n "${ip_hint}" ]] || ip_hint="-"
      [[ -n "${gw_hint}" ]] || gw_hint="-"

      append.tsv.row "${LXC_TSV_PATH}" \
        "lxc" "${id}" "${name}" "${status}" "${slot}" "${guest_if}" \
        "${bridge_name}" "${vlan_tag}" "${trunks}" "${firewall}" "${mtu}" \
        "${ip_hint}" "${gw_hint}" "${body}"

      if [[ "${bridge_name}" == "${EXPECTED_ADMIN_BRIDGE}" ]]; then
        has_admin_nic=1
        admin_nic_name="${guest_if}"
      fi
      if [[ "${bridge_name}" == "${EXPECTED_DATA_BRIDGE}" ]]; then
        has_data_nic=1
        data_nic_name="${guest_if}"
      fi
    done < <(grep -E '^net[0-9]+:' "${conf_path}" 2>/dev/null || true)

    if [[ "${has_admin_nic}" -eq 1 && "${has_data_nic}" -eq 0 ]]; then
      append.risk "warn" "lxc" "${id}" "${name}" "missing_data_nic" \
        "Container is attached to ${EXPECTED_ADMIN_BRIDGE} but has no NIC on ${EXPECTED_DATA_BRIDGE}."
    fi
    if [[ "${has_data_nic}" -eq 1 && "${has_admin_nic}" -eq 0 ]]; then
      append.risk "warn" "lxc" "${id}" "${name}" "missing_admin_nic" \
        "Container has a data-path NIC on ${EXPECTED_DATA_BRIDGE} but no NIC on ${EXPECTED_ADMIN_BRIDGE}."
    fi

    if [[ "${status}" == "running" ]]; then
      guest_sysctl_keys="net.ipv4.conf.all.arp_ignore net.ipv4.conf.all.arp_announce net.ipv4.conf.all.rp_filter"
      if [[ -n "${admin_nic_name}" && "${admin_nic_name}" != "-" ]]; then
        guest_sysctl_keys+=" net.ipv4.conf.${admin_nic_name}.rp_filter"
      fi
      if [[ -n "${data_nic_name}" && "${data_nic_name}" != "-" ]]; then
        guest_sysctl_keys+=" net.ipv4.conf.${data_nic_name}.rp_filter"
      fi
      capture.cmd "${runtime_dir}/ip.o4.addr.txt" "pct exec ${id} -- ip -o -4 addr show" "pct exec ${id} -- ip -o -4 addr show"
      capture.cmd "${runtime_dir}/ip.route.txt" "pct exec ${id} -- ip route" "pct exec ${id} -- ip route"
      capture.cmd "${runtime_dir}/ss.ltnp.txt" "pct exec ${id} -- ss -ltnp" "pct exec ${id} -- ss -ltnp"
      capture.cmd "${runtime_dir}/interfaces.txt" "pct exec ${id} -- cat /etc/network/interfaces" "pct exec ${id} -- cat /etc/network/interfaces"
      capture.cmd "${runtime_dir}/interfaces.d.list.txt" "pct exec ${id} -- ls -1 /etc/network/interfaces.d" "pct exec ${id} -- bash -lc 'ls -1 /etc/network/interfaces.d 2>/dev/null || true'"
      capture.cmd "${runtime_dir}/sysctl.arp-rpf.txt" "pct exec ${id} -- sysctl ARP/rp_filter" \
        "pct exec ${id} -- bash -lc 'sysctl ${guest_sysctl_keys} 2>/dev/null || true'"
      capture.cmd "${runtime_dir}/samba.testparm.filtered.txt" "pct exec ${id} -- Samba effective network config" \
        "pct exec ${id} -- bash -lc 'if command -v testparm >/dev/null 2>&1; then testparm -s 2>/dev/null | grep -E \"interfaces =|bind interfaces only =|hosts allow =|smb ports =\" || true; fi'"
      capture.cmd "${runtime_dir}/samba.smbconf.filtered.txt" "pct exec ${id} -- Samba raw smb.conf network lines" \
        "pct exec ${id} -- bash -lc 'if [ -f /etc/samba/smb.conf ]; then grep -nE \"^[[:space:]]*(interfaces|bind interfaces only|hosts allow|smb ports) =\" /etc/samba/smb.conf || true; fi'"
      capture.cmd "${runtime_dir}/ufw.status.txt" "pct exec ${id} -- ufw status numbered" \
        "pct exec ${id} -- bash -lc 'if command -v ufw >/dev/null 2>&1; then ufw status numbered; else echo ufw-not-installed; fi'"

      runtime_iface_summary="$(awk '$1 !~ /^#/ && NF >= 4 {print $2 "=" $4}' "${runtime_dir}/ip.o4.addr.txt" 2>/dev/null | paste -sd, -)"
      runtime_default_route="$(awk '$1 !~ /^#/ && /^default / {print; exit}' "${runtime_dir}/ip.route.txt" 2>/dev/null || true)"
      listen_summary="$(awk '$1 !~ /^#/ && /:22 |:22$|:445 |:445$/ {print}' "${runtime_dir}/ss.ltnp.txt" 2>/dev/null | paste -sd ';' -)"
      sysctl_summary="$(awk -F'= ' '$1 !~ /^#/ && /arp_ignore|arp_announce|rp_filter/ {gsub(/^[[:space:]]+/, "", $2); printf "%s=%s;", $1, $2}' "${runtime_dir}/sysctl.arp-rpf.txt" 2>/dev/null || true)"

      append.tsv.row "${GUEST_RUNTIME_TSV_PATH}" \
        "lxc" "${id}" "${name}" "${status}" "pct-exec" \
        "${runtime_iface_summary}" "${runtime_default_route}" "${listen_summary}" "${sysctl_summary}"

      testparm_interfaces="$(awk -F'= ' '$1 !~ /^#/ && /interfaces =/ {print $2; exit}' "${runtime_dir}/samba.testparm.filtered.txt" 2>/dev/null || true)"
      testparm_bind_only="$(awk -F'= ' '$1 !~ /^#/ && /bind interfaces only =/ {print $2; exit}' "${runtime_dir}/samba.testparm.filtered.txt" 2>/dev/null || true)"
      testparm_hosts_allow="$(awk -F'= ' '$1 !~ /^#/ && /hosts allow =/ {print $2; exit}' "${runtime_dir}/samba.testparm.filtered.txt" 2>/dev/null || true)"
      testparm_smb_ports="$(awk -F'= ' '$1 !~ /^#/ && /smb ports =/ {print $2; exit}' "${runtime_dir}/samba.testparm.filtered.txt" 2>/dev/null || true)"
      ufw_summary="$(first_line "${runtime_dir}/ufw.status.txt")"

      service_present="no"
      if awk '$0 !~ /^#/ && /interfaces =|bind interfaces only =|hosts allow =|smb ports =/ {found=1} END {exit(found ? 0 : 1)}' \
        "${runtime_dir}/samba.testparm.filtered.txt" "${runtime_dir}/samba.smbconf.filtered.txt" 2>/dev/null; then
        service_present="yes"
      fi

      append.tsv.row "${SAMBA_TSV_PATH}" \
        "lxc" "${id}" "${name}" "${status}" "${service_present}" \
        "${testparm_interfaces}" "${testparm_bind_only}" "${testparm_hosts_allow}" \
        "${testparm_smb_ports}" "${ufw_summary}"

      if [[ -n "${data_nic_name}" && "${data_nic_name}" != "-" && -n "${runtime_default_route}" && "${runtime_default_route}" == *"dev ${data_nic_name}"* ]]; then
        append.risk "warn" "lxc" "${id}" "${name}" "data_nic_default_route" \
          "Default route currently points at data interface ${data_nic_name}; egress-role selection must be reviewed."
      fi
      if [[ "${service_present}" == "yes" && -n "${admin_nic_name}" && "${admin_nic_name}" != "-" && "${testparm_interfaces}" == *"${admin_nic_name}"* ]]; then
        append.risk "warn" "samba" "${id}" "${name}" "samba_bound_to_admin_if" \
          "Samba interfaces include egress interface ${admin_nic_name}; file traffic may leak onto the management path."
      fi
      if [[ "${service_present}" == "yes" && -n "${data_nic_name}" && "${testparm_interfaces}" != *"${data_nic_name}"* ]]; then
        append.risk "warn" "samba" "${id}" "${name}" "samba_missing_data_if" \
          "Samba interfaces do not include the container data NIC ${data_nic_name}."
      fi
      if [[ "${testparm_hosts_allow}" == *"192.168.0.0/16"* ]]; then
        append.risk "warn" "samba" "${id}" "${name}" "legacy_broad_hosts_allow" \
          "Samba hosts allow still includes 192.168.0.0/16."
      fi
      if [[ "${service_present}" == "yes" && -n "${EXPECTED_DATA_CIDR}" && "${testparm_hosts_allow}" != *"${EXPECTED_DATA_CIDR}"* ]]; then
        append.risk "warn" "samba" "${id}" "${name}" "expected_lan_missing_from_hosts_allow" \
          "Samba hosts allow does not clearly include data CIDR ${EXPECTED_DATA_CIDR}."
      fi
    else
      append.tsv.row "${GUEST_RUNTIME_TSV_PATH}" \
        "lxc" "${id}" "${name}" "${status}" "unavailable" "-" "-" "-" "-"
      append.tsv.row "${SAMBA_TSV_PATH}" \
        "lxc" "${id}" "${name}" "${status}" "unknown" "-" "-" "-" "-" "-"
    fi
  done
  collected_count="$(tsv.data.row.count "${LXC_TSV_PATH}")"
  log "Collected LXC facts: ${collected_count} NIC rows"
}

collect.vm.data() {
  set.stage "collect.vm.data"
  printf 'guest_type\tguest_id\tguest_name\tstatus\tnet_slot\tmodel\tmac\tbridge\tvlan_tag\ttrunks\tfirewall\tmtu\traw\n' > "${VM_TSV_PATH}"

  local id=""
  local collected_count=""
  local status=""
  local conf_path=""
  local runtime_dir=""
  local name=""
  local line=""
  local slot=""
  local body=""
  local first=""
  local model=""
  local mac=""
  local bridge_name=""
  local vlan_tag=""
  local trunks=""
  local firewall=""
  local mtu=""
  local qga_state=""

  for id in "${VM_IDS[@]}"; do
    log "Inspecting VM ${id}"
    status="$(qm status "${id}" 2>/dev/null | awk '{print $2}' || true)"
    runtime_dir="${RAW_VM_DIR}/${id}"
    mkdir -p "${runtime_dir}"

    capture.cmd "${runtime_dir}/config.txt" "qm config ${id}" "qm config ${id}"
    conf_path="${runtime_dir}/config.txt"
    name="$(awk -F': ' '/^name:/ {print $2; exit}' "${conf_path}" 2>/dev/null || true)"
    [[ -n "${name}" ]] || name="vm${id}"

    while IFS= read -r line; do
      slot="${line%%:*}"
      body="${line#*: }"
      first="${body%%,*}"
      model="${first%%=*}"
      mac="${first#*=}"
      bridge_name="$(extract.csv.kv "${body}" "bridge" || true)"
      vlan_tag="$(extract.csv.kv "${body}" "tag" || true)"
      trunks="$(extract.csv.kv "${body}" "trunks" || true)"
      firewall="$(extract.csv.kv "${body}" "firewall" || true)"
      mtu="$(extract.csv.kv "${body}" "mtu" || true)"

      [[ -n "${bridge_name}" ]] || bridge_name="-"
      [[ -n "${vlan_tag}" ]] || vlan_tag="-"
      [[ -n "${trunks}" ]] || trunks="-"
      [[ -n "${firewall}" ]] || firewall="-"
      [[ -n "${mtu}" ]] || mtu="-"

      append.tsv.row "${VM_TSV_PATH}" \
        "vm" "${id}" "${name}" "${status}" "${slot}" "${model}" "${mac}" \
        "${bridge_name}" "${vlan_tag}" "${trunks}" "${firewall}" "${mtu}" "${body}"

      if [[ "${bridge_name}" == "${EXPECTED_ADMIN_BRIDGE}" && "${body}" != *"bridge=${EXPECTED_DATA_BRIDGE}"* ]]; then
        append.risk "info" "vm" "${id}" "${name}" "vm_admin_bridge_attachment" \
          "VM NIC ${slot} is attached to ${EXPECTED_ADMIN_BRIDGE}."
      fi
    done < <(grep -E '^net[0-9]+:' "${conf_path}" 2>/dev/null || true)

    if [[ "${status}" == "running" ]]; then
      capture.cmd "${runtime_dir}/qga.network.json" "qm guest cmd ${id} network-get-interfaces" \
        "qm guest cmd ${id} network-get-interfaces"
      qga_state="unavailable"
      if grep -q '\"name\"' "${runtime_dir}/qga.network.json" 2>/dev/null; then
        qga_state="available"
      fi
      append.tsv.row "${GUEST_RUNTIME_TSV_PATH}" \
        "vm" "${id}" "${name}" "${status}" "${qga_state}" "-" "-" "-" "-"
      if [[ "${qga_state}" != "available" ]]; then
        append.risk "info" "vm" "${id}" "${name}" "guest_agent_unavailable" \
          "VM guest agent network-get-interfaces is unavailable."
      fi
    else
      append.tsv.row "${GUEST_RUNTIME_TSV_PATH}" \
        "vm" "${id}" "${name}" "${status}" "unavailable" "-" "-" "-" "-"
    fi
  done
  collected_count="$(tsv.data.row.count "${VM_TSV_PATH}")"
  log "Collected VM facts: ${collected_count} NIC rows"
}

classify.host.risks() {
  set.stage "classify.host.risks"
  printf 'severity\tscope\tguest_id\tguest_name\tcode\tdetail\n' > "${RISKS_TSV_PATH}"

  local data_bridge_row=""
  local data_members=""
  local data_ipv4=""
  local data_vlan_filtering=""
  local collected_count=""

  data_bridge_row="$(awk -F'\t' -v bridge="${EXPECTED_DATA_BRIDGE}" '$1 == bridge {print $0; exit}' "${BRIDGES_TSV_PATH}" 2>/dev/null || true)"
  if [[ -z "${EXPECTED_DATA_BRIDGE}" ]]; then
    append.risk "error" "host" "-" "${HOSTNAME_SHORT}" "data_bridge_selection_required" \
      "No unique data bridge was discovered; operator selection is required."
  elif [[ -z "${data_bridge_row}" ]]; then
    append.risk "error" "host" "-" "${HOSTNAME_SHORT}" "missing_data_bridge" \
      "Expected data bridge ${EXPECTED_DATA_BRIDGE} was not found."
  else
    data_vlan_filtering="$(awk -F'\t' -v bridge="${EXPECTED_DATA_BRIDGE}" '$1 == bridge {print $2; exit}' "${BRIDGES_TSV_PATH}" 2>/dev/null || true)"
    data_members="$(awk -F'\t' -v bridge="${EXPECTED_DATA_BRIDGE}" '$1 == bridge {print $3; exit}' "${BRIDGES_TSV_PATH}" 2>/dev/null || true)"
    data_ipv4="$(awk -F'\t' -v bridge="${EXPECTED_DATA_BRIDGE}" '$1 == bridge {print $4; exit}' "${BRIDGES_TSV_PATH}" 2>/dev/null || true)"

    if [[ "${EXPECTED_DATA_LINK_MODE}" == "vlan-aware" && "${data_vlan_filtering}" != "1" ]]; then
      append.risk "warn" "host" "-" "${HOSTNAME_SHORT}" "data_bridge_not_vlan_aware" \
        "Bridge ${EXPECTED_DATA_BRIDGE} does not report vlan_filtering=1."
    fi
    if [[ "${EXPECTED_DATA_LINK_MODE}" == "untagged" && "${data_vlan_filtering}" == "1" ]]; then
      append.risk "warn" "host" "-" "${HOSTNAME_SHORT}" "untagged_bridge_vlan_filtering_enabled" \
        "Bridge ${EXPECTED_DATA_BRIDGE} is selected as untagged but reports vlan_filtering=1."
    fi
    if [[ -z "${data_members}" ]]; then
      append.risk "warn" "host" "-" "${HOSTNAME_SHORT}" "data_bridge_no_members" \
        "Bridge ${EXPECTED_DATA_BRIDGE} has no visible members."
    fi
    if [[ -n "${data_ipv4}" ]]; then
      append.risk "info" "host" "-" "${HOSTNAME_SHORT}" "data_bridge_has_ipv4" \
        "Bridge ${EXPECTED_DATA_BRIDGE} currently carries IPv4 address(es): ${data_ipv4}."
    fi
  fi

  if [[ -z "${DISCOVERED_DATA_NICS}" ]]; then
    append.risk "warn" "host" "-" "${HOSTNAME_SHORT}" "missing_physical_data_nic_member" \
      "No physical NIC is visibly enslaved to ${EXPECTED_DATA_BRIDGE}."
  fi

  if ! awk -F'\t' -v bridge="${EXPECTED_ADMIN_BRIDGE}" '$1 == bridge {found=1} END {exit(found ? 0 : 1)}' "${BRIDGES_TSV_PATH}" 2>/dev/null; then
    append.risk "warn" "host" "-" "${HOSTNAME_SHORT}" "expected_admin_bridge_missing" \
      "Expected admin bridge ${EXPECTED_ADMIN_BRIDGE} was not found."
  fi

  if [[ -n "${DISCOVERED_ADMIN_BRIDGE}" && "${DISCOVERED_ADMIN_BRIDGE}" != "${EXPECTED_ADMIN_BRIDGE}" ]]; then
    append.risk "info" "host" "-" "${HOSTNAME_SHORT}" "admin_bridge_differs_from_expectation" \
      "Default-route admin bridge appears to be ${DISCOVERED_ADMIN_BRIDGE}, not ${EXPECTED_ADMIN_BRIDGE}."
  fi

  awk -F'\t' -v bridge="${EXPECTED_DATA_BRIDGE}" '$11 == bridge && $2 == "physical" && $12 != "" {print $1 "\t" $12}' "${NICS_TSV_PATH}" 2>/dev/null | \
  while IFS=$'\t' read -r iface ipv4; do
    [[ -n "${iface}" ]] || continue
    append.risk "warn" "host" "-" "${HOSTNAME_SHORT}" "data_nic_has_host_ip" \
      "Physical data NIC ${iface} under ${EXPECTED_DATA_BRIDGE} has host IPv4 address(es): ${ipv4}."
  done
  collected_count="$(tsv.data.row.count "${RISKS_TSV_PATH}")"
  log "Classified risks: ${collected_count} findings"
}

validate.collection.artifacts() {
  set.stage "validate.collection.artifacts"
  tsv.validate.schema "${NICS_TSV_PATH}" $'iface\tkind\tmac\tmtu\toperstate\tcarrier\tspeed\tduplex\tdriver\tpci_slot\tmaster\tipv4\tipv6' 13
  tsv.validate.schema "${BRIDGES_TSV_PATH}" $'bridge\tvlan_filtering\tmembers\tipv4\tipv6' 5
  tsv.validate.schema "${VLANS_TSV_PATH}" $'port\tvlan_detail' 2
  tsv.validate.schema "${LXC_TSV_PATH}" $'guest_type\tguest_id\tguest_name\tstatus\tnet_slot\tguest_if\tbridge\tvlan_tag\ttrunks\tfirewall\tmtu\tip_hint\tgw_hint\traw' 14
  tsv.validate.schema "${VM_TSV_PATH}" $'guest_type\tguest_id\tguest_name\tstatus\tnet_slot\tmodel\tmac\tbridge\tvlan_tag\ttrunks\tfirewall\tmtu\traw' 13
  tsv.validate.schema "${GUEST_RUNTIME_TSV_PATH}" $'guest_type\tguest_id\tguest_name\tstatus\truntime_source\tipv4_interfaces\tdefault_route\tlisten_summary\tsysctl_summary' 9
  tsv.validate.schema "${SAMBA_TSV_PATH}" $'guest_type\tguest_id\tguest_name\tstatus\tservice_present\tinterfaces\tbind_interfaces_only\thosts_allow\tsmb_ports\tufw_summary' 10
  tsv.validate.schema "${RISKS_TSV_PATH}" $'severity\tscope\tguest_id\tguest_name\tcode\tdetail' 6
  (( $(tsv.data.row.count "${NICS_TSV_PATH}") > 0 )) || return 1
  (( $(tsv.data.row.count "${BRIDGES_TSV_PATH}") > 0 )) || return 1
}

evaluate.snapshot.readiness() {
  local data_ipv4="" id="" risk_errors="0" data_nic="" data_nic_row="" data_nic_speed="" data_nic_driver="" speed_evidence=""
  SNAPSHOT_COLLECTION_COMPLETE="true"
  SNAPSHOT_READY_FOR_UPDATE="false"
  SNAPSHOT_BLOCKING_CODES=""

  [[ -n "${DISCOVERED_ADMIN_BRIDGE}" ]] || append.blocking.code "missing_management_bridge"
  [[ -n "${DISCOVERED_ADMIN_NICS}" ]] || append.blocking.code "missing_management_physical_nic"
  [[ -n "${EXPECTED_MANAGEMENT_CIDR}" ]] || append.blocking.code "missing_management_cidr"
  if [[ -n "${EXPECTED_MANAGEMENT_CIDR}" ]] && ! valid.ipv4.cidr "${EXPECTED_MANAGEMENT_CIDR}"; then
    append.blocking.code "invalid_management_cidr"
  fi
  [[ -n "${EXPECTED_DATA_BRIDGE}" ]] || append.blocking.code "data_bridge_selection_required"
  [[ -n "${DISCOVERED_DATA_BRIDGE}" ]] || append.blocking.code "missing_data_bridge"
  [[ -n "${DISCOVERED_DATA_NICS}" ]] || append.blocking.code "missing_physical_data_nic_member"
  if [[ ! "${MIN_DATA_SPEED_MBPS}" =~ ^[0-9]+$ ]] || ((MIN_DATA_SPEED_MBPS < 1000)); then
    append.blocking.code "invalid_minimum_data_speed"
  fi

  while IFS= read -r data_nic; do
    [[ -n "${data_nic}" ]] || continue
    data_nic_row="$(awk -F'\t' -v iface="${data_nic}" '$1 == iface && $2 == "physical" {print; exit}' "${NICS_TSV_PATH}")"
    data_nic_speed="$(awk -F'\t' '{print $7}' <<< "${data_nic_row}")"
    data_nic_driver="$(awk -F'\t' '{print $9}' <<< "${data_nic_row}")"
    speed_evidence="$(physical.nic.speed.evidence.mbps "${data_nic}" "${data_nic_driver}" "${data_nic_speed}")"
    if [[ ! "${MIN_DATA_SPEED_MBPS}" =~ ^[0-9]+$ ]] \
      || [[ ! "${speed_evidence}" =~ ^[0-9]+$ ]] \
      || ((speed_evidence < MIN_DATA_SPEED_MBPS)); then
      append.blocking.code "data_nic_below_minimum_speed"
    fi
  done < <(printf '%s' "${DISCOVERED_DATA_NICS}" | tr ',' '\n')

  if [[ -n "${DISCOVERED_DATA_BRIDGE}" ]]; then
    data_ipv4="$(awk -F'\t' -v bridge="${DISCOVERED_DATA_BRIDGE}" '$1 == bridge {print $4; exit}' "${BRIDGES_TSV_PATH}")"
    [[ -z "${data_ipv4}" ]] || append.blocking.code "data_bridge_has_host_ipv4"
  fi

  if ((${#CT_IDS[@]} == 0)); then
    append.blocking.code "no_selected_lxc"
  else
    for id in "${CT_IDS[@]}"; do
      if ! awk -F'\t' -v target="${id}" 'NR > 1 && $2 == target {found=1} END {exit(found ? 0 : 1)}' "${LXC_TSV_PATH}"; then
        append.blocking.code "selected_lxc_missing_network_rows"
      fi
    done
  fi

  risk_errors="$(awk -F'\t' '$1 == "error" {count++} END {print count + 0}' "${RISKS_TSV_PATH}")"
  ((risk_errors == 0)) || append.blocking.code "risk_errors_present"
  if [[ -z "${SNAPSHOT_BLOCKING_CODES}" ]]; then
    SNAPSHOT_READY_FOR_UPDATE="true"
  fi
}

write.snapshot.status() {
  local code=""
  [[ -n "${SNAPSHOT_STATUS_PATH:-}" ]] || return 0
  mkdir -p "$(dirname "${SNAPSHOT_STATUS_PATH}")"
  {
    printf '%s\n' '---'
    printf '%s\n' 'proxmox_network_snapshot:'
    printf '%s\n' '  schema_version: 1'
    printf '  hostname: %s\n' "$(yaml.quote "${HOSTNAME_SHORT:-unknown}")"
    printf '  collected_at: %s\n' "$(yaml.quote "${COLLECTED_AT:-unknown}")"
    printf '  run_dir: %s\n' "$(yaml.quote "${RUN_DIR:-}")"
    printf '  collection_complete: %s\n' "${SNAPSHOT_COLLECTION_COMPLETE}"
    printf '  ready_for_update: %s\n' "${SNAPSHOT_READY_FOR_UPDATE}"
    printf '  selected_data_bridge: %s\n' "$(yaml.quote "${EXPECTED_DATA_BRIDGE:-}")"
    printf '  live_data_bridge: %s\n' "$(yaml.quote "${DISCOVERED_DATA_BRIDGE:-}")"
    printf '  management_cidr: %s\n' "$(yaml.quote "${EXPECTED_MANAGEMENT_CIDR:-}")"
    printf '  minimum_data_speed_mbps: %s\n' "${MIN_DATA_SPEED_MBPS}"
    if [[ -z "${SNAPSHOT_BLOCKING_CODES}" ]]; then
      printf '%s\n' '  blocking_codes: []'
    else
      printf '%s\n' '  blocking_codes:'
      while IFS= read -r code; do
        [[ -n "${code}" ]] && printf '    - %s\n' "$(yaml.quote "${code}")"
      done < <(printf '%s' "${SNAPSHOT_BLOCKING_CODES}" | tr ',' '\n')
    fi
  } > "${SNAPSHOT_STATUS_PATH}"
}

mark.snapshot.ready() {
  [[ "${SNAPSHOT_COLLECTION_COMPLETE}" == "true" && "${SNAPSHOT_READY_FOR_UPDATE}" == "true" ]] || return 1
  {
    printf 'schema_version=1\n'
    printf 'hostname=%s\n' "${HOSTNAME_SHORT}"
    printf 'selected_data_bridge=%s\n' "${EXPECTED_DATA_BRIDGE}"
    printf 'live_data_bridge=%s\n' "${DISCOVERED_DATA_BRIDGE}"
  } > "${SNAPSHOT_READY_PATH}"
}

write.host.yaml() {
  set.stage "write.host.yaml"
  cat > "${HOST_YAML_PATH}" <<EOF
---
proxmox_network_preflight:
  collected_at: $(yaml.quote "${COLLECTED_AT}")
  hostname: $(yaml.quote "${HOSTNAME_SHORT}")
  output_root: $(yaml.quote "${OUTPUT_ROOT}")
  run_dir: $(yaml.quote "${RUN_DIR}")
  expected:
    admin_bridge: $(yaml.quote "${EXPECTED_ADMIN_BRIDGE}")
    data_bridge: $(yaml.quote "${EXPECTED_DATA_BRIDGE}")
    data_link_mode: $(yaml.quote "${EXPECTED_DATA_LINK_MODE}")
    management_cidr: $(yaml.quote "${EXPECTED_MANAGEMENT_CIDR}")
    data_cidr: $(yaml.quote "${EXPECTED_DATA_CIDR}")
    guest_admin_if: $(yaml.quote "${EXPECTED_GUEST_ADMIN_IF}")
    guest_data_if: $(yaml.quote "${EXPECTED_GUEST_DATA_IF}")
  discovered:
    pve_version: $(yaml.quote "${PVE_VERSION}")
    kernel_version: $(yaml.quote "${KERNEL_VERSION}")
    default_route: $(yaml.quote "${DEFAULT_ROUTE_LINE}")
    default_gateway: $(yaml.quote "${DEFAULT_GATEWAY}")
    admin_bridge: $(yaml.quote "${DISCOVERED_ADMIN_BRIDGE}")
    admin_nic: $(yaml.quote "${DISCOVERED_ADMIN_NIC}")
    admin_nics: $(yaml.quote "${DISCOVERED_ADMIN_NICS}")
    admin_ip_cidr: $(yaml.quote "${DISCOVERED_ADMIN_IP_CIDR}")
    selected_data_bridge: $(yaml.quote "${EXPECTED_DATA_BRIDGE}")
    live_data_bridge: $(yaml.quote "${DISCOVERED_DATA_BRIDGE}")
    data_nics: $(yaml.quote "${DISCOVERED_DATA_NICS}")
  artifacts:
    summary: $(yaml.quote "${SUMMARY_PATH}")
    next_stage_env: $(yaml.quote "${ENV_PATH}")
    nics_tsv: $(yaml.quote "${NICS_TSV_PATH}")
    bridges_tsv: $(yaml.quote "${BRIDGES_TSV_PATH}")
    vlans_tsv: $(yaml.quote "${VLANS_TSV_PATH}")
    lxc_tsv: $(yaml.quote "${LXC_TSV_PATH}")
    vm_tsv: $(yaml.quote "${VM_TSV_PATH}")
    guest_runtime_tsv: $(yaml.quote "${GUEST_RUNTIME_TSV_PATH}")
    samba_tsv: $(yaml.quote "${SAMBA_TSV_PATH}")
    risks_tsv: $(yaml.quote "${RISKS_TSV_PATH}")
    snapshot_status: $(yaml.quote "${SNAPSHOT_STATUS_PATH}")
    snapshot_ready: $(yaml.quote "${SNAPSHOT_READY_PATH}")
EOF
}

write.next.stage.env() {
  set.stage "write.next.stage.env"
  cat > "${ENV_PATH}" <<EOF
# Saved by setup/network.sh preflight
export PROXMOX_NETWORK_REPORT_DIR=$(yaml.quote "${RUN_DIR}")
export PROXMOX_NETWORK_EXPECTED_ADMIN_BRIDGE=$(yaml.quote "${EXPECTED_ADMIN_BRIDGE}")
export PROXMOX_NETWORK_EXPECTED_DATA_BRIDGE=$(yaml.quote "${EXPECTED_DATA_BRIDGE}")
export PROXMOX_NETWORK_EXPECTED_DATA_LINK_MODE=$(yaml.quote "${EXPECTED_DATA_LINK_MODE}")
export PROXMOX_NETWORK_MANAGEMENT_CIDR=$(yaml.quote "${EXPECTED_MANAGEMENT_CIDR}")
export PROXMOX_NETWORK_DATA_CIDR=$(yaml.quote "${EXPECTED_DATA_CIDR}")
export PROXMOX_NETWORK_EXPECTED_GUEST_ADMIN_IF=$(yaml.quote "${EXPECTED_GUEST_ADMIN_IF}")
export PROXMOX_NETWORK_EXPECTED_GUEST_DATA_IF=$(yaml.quote "${EXPECTED_GUEST_DATA_IF}")
export PROXMOX_NETWORK_DISCOVERED_ADMIN_BRIDGE=$(yaml.quote "${DISCOVERED_ADMIN_BRIDGE}")
export PROXMOX_NETWORK_DISCOVERED_ADMIN_NIC=$(yaml.quote "${DISCOVERED_ADMIN_NIC}")
export PROXMOX_NETWORK_DISCOVERED_ADMIN_NICS=$(yaml.quote "${DISCOVERED_ADMIN_NICS}")
export PROXMOX_NETWORK_DISCOVERED_ADMIN_IP_CIDR=$(yaml.quote "${DISCOVERED_ADMIN_IP_CIDR}")
export PROXMOX_NETWORK_DISCOVERED_DATA_BRIDGE=$(yaml.quote "${DISCOVERED_DATA_BRIDGE}")
export PROXMOX_NETWORK_DISCOVERED_DATA_NICS=$(yaml.quote "${DISCOVERED_DATA_NICS}")
export PROXMOX_NETWORK_DEFAULT_GATEWAY=$(yaml.quote "${DEFAULT_GATEWAY}")
EOF
}

export.preflight.facts.for.ansible() {
  set.stage "export.preflight.facts.for.ansible"
  mkdir -p "${FACTS_DIR}"

  cat > "${ANSIBLE_PREFLIGHT_FACTS_YAML}" <<EOF
---
proxmox_network_preflight_latest:
  generated_by: "setup/network.sh"
  generated_at: $(yaml.quote "${COLLECTED_AT}")
  hostname: $(yaml.quote "${HOSTNAME_SHORT}")
  run_dir: $(yaml.quote "${RUN_DIR}")
  expected:
    admin_bridge: $(yaml.quote "${EXPECTED_ADMIN_BRIDGE}")
    data_bridge: $(yaml.quote "${EXPECTED_DATA_BRIDGE}")
    data_link_mode: $(yaml.quote "${EXPECTED_DATA_LINK_MODE}")
    management_cidr: $(yaml.quote "${EXPECTED_MANAGEMENT_CIDR}")
    data_cidr: $(yaml.quote "${EXPECTED_DATA_CIDR}")
    guest_admin_if: $(yaml.quote "${EXPECTED_GUEST_ADMIN_IF}")
    guest_data_if: $(yaml.quote "${EXPECTED_GUEST_DATA_IF}")
  discovered:
    admin_bridge: $(yaml.quote "${DISCOVERED_ADMIN_BRIDGE}")
    admin_nic: $(yaml.quote "${DISCOVERED_ADMIN_NIC}")
    admin_nics: $(yaml.quote "${DISCOVERED_ADMIN_NICS}")
    admin_ip_cidr: $(yaml.quote "${DISCOVERED_ADMIN_IP_CIDR}")
    live_data_bridge: $(yaml.quote "${DISCOVERED_DATA_BRIDGE}")
    data_nics: $(yaml.quote "${DISCOVERED_DATA_NICS}")
    default_gateway: $(yaml.quote "${DEFAULT_GATEWAY}")
  artifacts:
    host_yaml: $(yaml.quote "${HOST_YAML_PATH}")
    summary: $(yaml.quote "${SUMMARY_PATH}")
    env: $(yaml.quote "${ENV_PATH}")
    nics_tsv: $(yaml.quote "${NICS_TSV_PATH}")
    bridges_tsv: $(yaml.quote "${BRIDGES_TSV_PATH}")
    vlans_tsv: $(yaml.quote "${VLANS_TSV_PATH}")
    lxc_tsv: $(yaml.quote "${LXC_TSV_PATH}")
    vm_tsv: $(yaml.quote "${VM_TSV_PATH}")
    guest_runtime_tsv: $(yaml.quote "${GUEST_RUNTIME_TSV_PATH}")
    samba_tsv: $(yaml.quote "${SAMBA_TSV_PATH}")
    risks_tsv: $(yaml.quote "${RISKS_TSV_PATH}")
    snapshot_status: $(yaml.quote "${SNAPSHOT_STATUS_PATH}")
    snapshot_ready: $(yaml.quote "${SNAPSHOT_READY_PATH}")
EOF

  cp -f "${LXC_TSV_PATH}" "${FACTS_DIR}/network.lxc.latest.tsv"
  cp -f "${VM_TSV_PATH}" "${FACTS_DIR}/network.vm.latest.tsv"
  cp -f "${NICS_TSV_PATH}" "${FACTS_DIR}/network.nics.latest.tsv"
  cp -f "${BRIDGES_TSV_PATH}" "${FACTS_DIR}/network.bridges.latest.tsv"
  cp -f "${RISKS_TSV_PATH}" "${FACTS_DIR}/network.risks.latest.tsv"
  cp -f "${SUMMARY_PATH}" "${FACTS_DIR}/network.summary.latest.txt"

  cat > "${ANSIBLE_PREFLIGHT_FACTS_JSON}" <<EOF
{"proxmox_network_preflight_latest":{"generated_by":"setup/network.sh","generated_at":"${COLLECTED_AT}","hostname":"${HOSTNAME_SHORT}","run_dir":"${RUN_DIR}","expected":{"admin_bridge":"${EXPECTED_ADMIN_BRIDGE}","data_bridge":"${EXPECTED_DATA_BRIDGE}","management_cidr":"${EXPECTED_MANAGEMENT_CIDR}","data_cidr":"${EXPECTED_DATA_CIDR}","guest_admin_if":"${EXPECTED_GUEST_ADMIN_IF}","guest_data_if":"${EXPECTED_GUEST_DATA_IF}"},"discovered":{"admin_bridge":"${DISCOVERED_ADMIN_BRIDGE}","admin_nic":"${DISCOVERED_ADMIN_NIC}","admin_nics":"${DISCOVERED_ADMIN_NICS}","admin_ip_cidr":"${DISCOVERED_ADMIN_IP_CIDR}","live_data_bridge":"${DISCOVERED_DATA_BRIDGE}","data_nics":"${DISCOVERED_DATA_NICS}","default_gateway":"${DEFAULT_GATEWAY}"}}}
EOF
  log "Exported preflight facts for Ansible: ${ANSIBLE_PREFLIGHT_FACTS_YAML}"
}

write.summary() {
  set.stage "write.summary"
  local ct_count vm_count nic_count bridge_count risk_total risk_error risk_warn risk_info
  ct_count="$(tsv.data.row.count "${LXC_TSV_PATH}")"
  vm_count="$(tsv.data.row.count "${VM_TSV_PATH}")"
  nic_count="$(tsv.data.row.count "${NICS_TSV_PATH}")"
  bridge_count="$(tsv.data.row.count "${BRIDGES_TSV_PATH}")"
  risk_total="$(tsv.data.row.count "${RISKS_TSV_PATH}")"
  risk_error="$(awk -F'\t' '$1 == "error" {count++} END {print count + 0}' "${RISKS_TSV_PATH}")"
  risk_warn="$(awk -F'\t' '$1 == "warn" {count++} END {print count + 0}' "${RISKS_TSV_PATH}")"
  risk_info="$(awk -F'\t' '$1 == "info" {count++} END {print count + 0}' "${RISKS_TSV_PATH}")"

  {
    printf 'Proxmox Network Preflight Summary\n'
    printf 'Host: %s\n' "${HOSTNAME_SHORT}"
    printf 'Collected: %s\n' "${COLLECTED_AT}"
    printf 'Run Directory: %s\n' "${RUN_DIR}"
    printf 'Collection Complete: %s\n' "${SNAPSHOT_COLLECTION_COMPLETE}"
    printf 'Ready For Update: %s\n' "${SNAPSHOT_READY_FOR_UPDATE}"
    printf 'Blocking Codes: %s\n' "${SNAPSHOT_BLOCKING_CODES:-none}"
    printf '\n'
    printf 'Expected Admin Bridge: %s\n' "${EXPECTED_ADMIN_BRIDGE}"
    printf 'Expected Data Bridge: %s\n' "${EXPECTED_DATA_BRIDGE}"
    printf 'Management CIDR: %s\n' "${EXPECTED_MANAGEMENT_CIDR}"
    printf 'Data CIDR: %s\n' "${EXPECTED_DATA_CIDR:-not-selected}"
    printf '\n'
    printf 'Discovered Admin Bridge: %s\n' "${DISCOVERED_ADMIN_BRIDGE}"
    printf 'Discovered Admin Physical NICs: %s\n' "${DISCOVERED_ADMIN_NICS:-none}"
    printf 'Discovered Admin IP/CIDR: %s\n' "${DISCOVERED_ADMIN_IP_CIDR}"
    printf 'Live Data Bridge: %s\n' "${DISCOVERED_DATA_BRIDGE:-missing}"
    printf 'Discovered Data NICs On %s: %s\n' "${EXPECTED_DATA_BRIDGE}" "${DISCOVERED_DATA_NICS:-none}"
    printf 'Default Gateway: %s\n' "${DEFAULT_GATEWAY}"
    printf '\n'
    printf 'Counts:\n'
    printf '  NICs: %s\n' "${nic_count}"
    printf '  Bridges: %s\n' "${bridge_count}"
    printf '  LXC NIC rows: %s\n' "${ct_count}"
    printf '  VM NIC rows: %s\n' "${vm_count}"
    printf '  Risks: total=%s error=%s warn=%s info=%s\n' "${risk_total}" "${risk_error}" "${risk_warn}" "${risk_info}"
    printf '\n'
    printf 'Top Risks:\n'
    awk -F'\t' 'NR > 1 {printf "  - [%s] %s/%s: %s\n", $1, $2, $5, $6}' "${RISKS_TSV_PATH}" 2>/dev/null | head -n 12
    printf '\n'
    printf 'Saved Artifacts:\n'
    printf '  - %s\n' "${HOST_YAML_PATH}"
    printf '  - %s\n' "${NICS_TSV_PATH}"
    printf '  - %s\n' "${BRIDGES_TSV_PATH}"
    printf '  - %s\n' "${VLANS_TSV_PATH}"
    printf '  - %s\n' "${LXC_TSV_PATH}"
    printf '  - %s\n' "${VM_TSV_PATH}"
    printf '  - %s\n' "${GUEST_RUNTIME_TSV_PATH}"
    printf '  - %s\n' "${SAMBA_TSV_PATH}"
    printf '  - %s\n' "${RISKS_TSV_PATH}"
    printf '  - %s\n' "${SNAPSHOT_STATUS_PATH}"
    if [[ "${SNAPSHOT_READY_FOR_UPDATE}" == "true" ]]; then
      printf '  - %s\n' "${SNAPSHOT_READY_PATH}"
      printf '  - %s\n' "${ENV_PATH}"
      printf '  - %s\n' "${ANSIBLE_PREFLIGHT_FACTS_YAML}"
      printf '  - %s\n' "${ANSIBLE_PREFLIGHT_FACTS_JSON}"
    fi
    printf '\n'
    printf 'Suggested Next Step:\n'
    if [[ "${SNAPSHOT_READY_FOR_UPDATE}" == "true" ]]; then
      printf '  source %s\n' "${ENV_PATH}"
      printf '  wget -qO- https://devs-guide.github.io/proxmox/setup/network.sh | bash -s -- update\n'
    else
      printf '  Resolve the blocking codes above. For a missing data bridge, run setup.vlan.sh preflight/apply first, then rerun this preflight.\n'
    fi
  } > "${SUMMARY_PATH}"
}

print.discovery.preview() {
  printf '\n'
  printf 'Discovered host defaults:\n' >&3
  printf '  host: %s\n' "${HOSTNAME_SHORT}" >&3
  printf '  output root: %s\n' "${OUTPUT_ROOT}" >&3
  printf '  admin bridge: %s\n' "${DISCOVERED_ADMIN_BRIDGE:-${EXPECTED_ADMIN_BRIDGE}}" >&3
  printf '  admin physical nics: %s\n' "${DISCOVERED_ADMIN_NICS:-unknown}" >&3
  printf '  admin ip: %s\n' "${DISCOVERED_ADMIN_IP_CIDR:-none}" >&3
  printf '  default gateway: %s\n' "${DEFAULT_GATEWAY:-none}" >&3
  printf '  selected data bridge: %s\n' "${EXPECTED_DATA_BRIDGE:-selection-required}" >&3
  printf '  live data bridge: %s\n' "${DISCOVERED_DATA_BRIDGE:-missing}" >&3
  printf '  guest admin if: %s\n' "${EXPECTED_GUEST_ADMIN_IF}" >&3
  printf '  guest data if: %s\n' "${EXPECTED_GUEST_DATA_IF}" >&3
  printf '  management CIDR: %s\n' "${EXPECTED_MANAGEMENT_CIDR}" >&3
  printf '  discovered LXC IDs: %s\n' "$(join.discovered.ids DISCOVERED_CT_IDS)" >&3
  printf '  discovered VM IDs: %s\n' "$(join.discovered.ids DISCOVERED_VM_IDS)" >&3
  printf '\n' >&3
}

collect.operator.selection() {
  local choice=""
  local discovered_ctids=""
  local discovered_vmids=""

  if ! is.true "${FEATURE_INTERACTIVE}" || ! open.tty; then
    return 0
  fi

  discovered_ctids="$(join.discovered.ids DISCOVERED_CT_IDS)"
  discovered_vmids="$(join.discovered.ids DISCOVERED_VM_IDS)"
  print.discovery.preview

  choice="$(menu.tty "Accept discovered preflight defaults?" "yes" "edit values manually" "abort")"
  case "${choice}" in
    1)
      return 0
      ;;
    2)
      OUTPUT_ROOT="$(prompt.tty "Enter output root directory" "${OUTPUT_ROOT}")"
      EXPECTED_ADMIN_BRIDGE="$(prompt.tty "Enter expected admin bridge" "${DISCOVERED_ADMIN_BRIDGE:-${EXPECTED_ADMIN_BRIDGE}}")"
      EXPECTED_DATA_BRIDGE="$(prompt.tty "Enter expected data bridge" "${EXPECTED_DATA_BRIDGE}")"
      EXPECTED_MANAGEMENT_CIDR="$(prompt.tty "Enter management CIDR" "${EXPECTED_MANAGEMENT_CIDR}")"
      EXPECTED_GUEST_ADMIN_IF="$(prompt.tty "Enter guest admin interface name" "${EXPECTED_GUEST_ADMIN_IF}")"
      EXPECTED_GUEST_DATA_IF="$(prompt.tty "Enter guest data interface name" "${EXPECTED_GUEST_DATA_IF}")"
      CTID_FILTER="$(trim.space "$(prompt.tty "Enter LXC IDs to inspect (blank = all discovered)" "${CTID_FILTER}")")"
      VMID_FILTER="$(trim.space "$(prompt.tty "Enter VM IDs to inspect (blank = all discovered)" "${VMID_FILTER}")")"
      printf '\nFinal preflight selection:\n' >&3
      printf '  output root: %s\n' "${OUTPUT_ROOT}" >&3
      printf '  expected admin bridge: %s\n' "${EXPECTED_ADMIN_BRIDGE}" >&3
      printf '  expected data bridge: %s\n' "${EXPECTED_DATA_BRIDGE}" >&3
      printf '  management CIDR: %s\n' "${EXPECTED_MANAGEMENT_CIDR}" >&3
      printf '  guest admin if: %s\n' "${EXPECTED_GUEST_ADMIN_IF}" >&3
      printf '  guest data if: %s\n' "${EXPECTED_GUEST_DATA_IF}" >&3
      printf '  selected LXC IDs: %s\n' "${CTID_FILTER:-${discovered_ctids}}" >&3
      printf '  selected VM IDs: %s\n' "${VMID_FILTER:-${discovered_vmids}}" >&3
      printf '\n' >&3
      ;;
    *)
      log.error "Aborted by operator."
      exit 1
      ;;
  esac
}

resolve.snapshot.dir() {
  local resolved=""
  if [[ -n "${SNAPSHOT_DIR_OVERRIDE}" ]]; then
    resolved="${SNAPSHOT_DIR_OVERRIDE}"
  elif [[ -n "${REPORT_DIR_OVERRIDE}" ]]; then
    resolved="${REPORT_DIR_OVERRIDE}"
  elif [[ -L "${OUTPUT_ROOT}/latest-ready" ]]; then
    resolved="$(readlink "${OUTPUT_ROOT}/latest-ready")"
    if [[ "${resolved}" != /* ]]; then
      resolved="${OUTPUT_ROOT}/${resolved}"
    fi
  elif [[ -f "${OUTPUT_ROOT}/latest-ready.path" ]]; then
    resolved="$(cat "${OUTPUT_ROOT}/latest-ready.path")"
  fi

  if [[ -z "${resolved}" || ! -d "${resolved}" ]]; then
    log.error "No update-ready preflight snapshot directory found."
    log.error "Run setup/network.sh preflight after the data bridge exists, or set PROXMOX_NETWORK_SNAPSHOT_DIR to a ready snapshot."
    exit 1
  fi

  RUN_DIR="${resolved}"
  set.run.paths.from.dir
}

load.snapshot.defaults() {
  local env_file="${RUN_DIR}/network.next-stage.env"
  if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
    EXPECTED_ADMIN_BRIDGE="${PROXMOX_NETWORK_EXPECTED_ADMIN_BRIDGE:-${EXPECTED_ADMIN_BRIDGE}}"
    EXPECTED_DATA_BRIDGE="${PROXMOX_NETWORK_EXPECTED_DATA_BRIDGE:-${EXPECTED_DATA_BRIDGE}}"
    EXPECTED_DATA_LINK_MODE="${PROXMOX_NETWORK_EXPECTED_DATA_LINK_MODE:-${EXPECTED_DATA_LINK_MODE}}"
    EXPECTED_MANAGEMENT_CIDR="${PROXMOX_NETWORK_MANAGEMENT_CIDR:-${PROXMOX_NETWORK_EXPECTED_LAN_CIDR:-${EXPECTED_MANAGEMENT_CIDR}}}"
    EXPECTED_DATA_CIDR="${PROXMOX_NETWORK_DATA_CIDR:-${EXPECTED_DATA_CIDR}}"
    EXPECTED_GUEST_ADMIN_IF="${PROXMOX_NETWORK_EXPECTED_GUEST_ADMIN_IF:-${EXPECTED_GUEST_ADMIN_IF}}"
    EXPECTED_GUEST_DATA_IF="${PROXMOX_NETWORK_EXPECTED_GUEST_DATA_IF:-${EXPECTED_GUEST_DATA_IF}}"
  fi
}

require.snapshot.artifacts() {
  local missing=0
  local path=""
  for path in \
    "${SNAPSHOT_STATUS_PATH}" \
    "${SNAPSHOT_READY_PATH}" \
    "${ENV_PATH}" \
    "${NICS_TSV_PATH}" \
    "${BRIDGES_TSV_PATH}" \
    "${LXC_TSV_PATH}" \
    "${VM_TSV_PATH}" \
    "${RAW_LXC_DIR}" \
    "${RAW_VM_DIR}"; do
    if [[ ! -e "${path}" ]]; then
      log.error "Missing snapshot artifact for update mode: ${path}"
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
  if [[ -f "${RUN_DIR}/network.error.txt" ]]; then
    log.error "Snapshot contains a collection error marker: ${RUN_DIR}/network.error.txt"
    exit 1
  fi
  grep -Fxq '  collection_complete: true' "${SNAPSHOT_STATUS_PATH}" || {
    log.error "Snapshot collection is not complete: ${SNAPSHOT_STATUS_PATH}"
    exit 1
  }
  grep -Fxq '  ready_for_update: true' "${SNAPSHOT_STATUS_PATH}" || {
    log.error "Snapshot is not approved for update: ${SNAPSHOT_STATUS_PATH}"
    exit 1
  }
  grep -Fxq "selected_data_bridge=${EXPECTED_DATA_BRIDGE}" "${SNAPSHOT_READY_PATH}" || {
    log.error "Snapshot ready marker does not match selected data bridge ${EXPECTED_DATA_BRIDGE}."
    exit 1
  }
  validate.collection.artifacts || {
    log.error "Snapshot TSV schema validation failed; rerun preflight with the current runner."
    exit 1
  }
}

require.live.update.topology() {
  local route_line="" route_dev="" live_admin_bridge="" member_path="" member="" member_driver="" member_speed="" speed_evidence="" member_count=0 host_ipv4=""
  [[ "${MIN_DATA_SPEED_MBPS}" =~ ^[0-9]+$ ]] && ((MIN_DATA_SPEED_MBPS >= 1000)) || {
    log.error "PROXMOX_NETWORK_MIN_DATA_SPEED_MBPS must be an integer of at least 1000."
    exit 1
  }
  route_line="$(ip route show default 2>/dev/null | head -n1 || true)"
  route_dev="$(awk '/^default / {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "${route_line}")"
  live_admin_bridge="${route_dev}"
  if [[ -n "${route_dev}" && -L "${SYS_CLASS_NET_ROOT}/${route_dev}/master" ]]; then
    live_admin_bridge="$(readlink.basename.or.empty "${SYS_CLASS_NET_ROOT}/${route_dev}/master")"
  fi
  if [[ "${live_admin_bridge}" != "${EXPECTED_ADMIN_BRIDGE}" ]]; then
    log.error "Live management route changed: expected ${EXPECTED_ADMIN_BRIDGE}, found ${live_admin_bridge:-none}. Rerun preflight."
    exit 1
  fi
  if [[ ! -d "${SYS_CLASS_NET_ROOT}/${EXPECTED_DATA_BRIDGE}/bridge" ]] \
    || ! ip link show dev "${EXPECTED_DATA_BRIDGE}" >/dev/null 2>&1; then
    log.error "Selected data bridge is not live: ${EXPECTED_DATA_BRIDGE}."
    log.error "Run setup.vlan.sh preflight/apply to create the host data bridge, then rerun setup/network.sh preflight."
    exit 1
  fi
  for member_path in "${SYS_CLASS_NET_ROOT}/${EXPECTED_DATA_BRIDGE}"/brif/*; do
    [[ -e "${member_path}" ]] || continue
    member="$(basename "${member_path}")"
    if [[ -e "${SYS_CLASS_NET_ROOT}/${member}/device" ]]; then
      member_count=$((member_count + 1))
      member_driver="$(readlink.basename.or.empty "${SYS_CLASS_NET_ROOT}/${member}/device/driver")"
      member_speed="$(cat "${SYS_CLASS_NET_ROOT}/${member}/speed" 2>/dev/null || true)"
      speed_evidence="$(physical.nic.speed.evidence.mbps "${member}" "${member_driver}" "${member_speed}")"
      if [[ ! "${speed_evidence}" =~ ^[0-9]+$ ]] || ((speed_evidence < MIN_DATA_SPEED_MBPS)); then
        log.error "Physical data NIC ${member} has only ${speed_evidence:-0}Mbps of speed evidence; policy requires at least ${MIN_DATA_SPEED_MBPS}Mbps."
        exit 1
      fi
    fi
  done
  if ((member_count == 0)); then
    log.error "Data bridge ${EXPECTED_DATA_BRIDGE} has no physical NIC member."
    exit 1
  fi
  host_ipv4="$(ip -o -4 addr show dev "${EXPECTED_DATA_BRIDGE}" 2>/dev/null | awk '{print $4}' | paste -sd, - || true)"
  if [[ -n "${host_ipv4}" ]]; then
    log.error "Data bridge ${EXPECTED_DATA_BRIDGE} has host IPv4 address(es): ${host_ipv4}."
    log.error "The isolated ingest bridge must remain unnumbered on the Proxmox host."
    exit 1
  fi
}

use.local.feature.files() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"

  if [[ -r "${repo_root}/ansible/${NETWORK_EXPORT_PLAYBOOK_REL}" \
    && -r "${repo_root}/ansible/${NETWORK_UPDATE_PLAYBOOK_REL}" \
    && -r "${repo_root}/ansible/${NETWORK_VERIFY_PLAYBOOK_REL}" \
    && -r "${repo_root}/ansible/${NETWORK_LXC_NIC_HELPER_REL}" \
    && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]]; then
    PLAYBOOK_ROOT="${repo_root}/ansible"
    PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
    GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
    NETWORK_EXPORT_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_EXPORT_PLAYBOOK_REL}"
    NETWORK_UPDATE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_UPDATE_PLAYBOOK_REL}"
    NETWORK_VERIFY_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_VERIFY_PLAYBOOK_REL}"
    NETWORK_LXC_NIC_HELPER_PATH="${PLAYBOOK_ROOT}/${NETWORK_LXC_NIC_HELPER_REL}"
    log "Using local feature files from ${repo_root}."
    return 0
  fi

  return 1
}

fetch.feature.file() {
  local url="$1"
  local dest="$2"
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
  fetch.feature.file "${NETWORK_EXPORT_PLAYBOOK_URL}" "${NETWORK_EXPORT_PLAYBOOK_PATH}"
  fetch.feature.file "${NETWORK_UPDATE_PLAYBOOK_URL}" "${NETWORK_UPDATE_PLAYBOOK_PATH}"
  fetch.feature.file "${NETWORK_VERIFY_PLAYBOOK_URL}" "${NETWORK_VERIFY_PLAYBOOK_PATH}"
  fetch.feature.file "${NETWORK_LXC_NIC_HELPER_URL}" "${NETWORK_LXC_NIC_HELPER_PATH}"
}

run.feature.playbook() {
  local playbook_path="$1"
  shift || true
  ansible.runtime.run -i localhost, -c local -e "@${GROUP_VARS_PATH}" "$@" "${playbook_path}"
}

ensure.network.ansible() {
  source.release.common
  ensure.managed.ansible
}

pick.free.net.slot() {
  local config_path="${1:-}"
  local n=""
  [[ -f "${config_path}" ]] || {
    printf ''
    return 1
  }
  for n in 1 2 3 4 5 6 7 8 9; do
    if ! grep -qE "^net${n}:" "${config_path}" 2>/dev/null; then
      printf 'net%s' "${n}"
      return 0
    fi
  done
  printf ''
  return 1
}

lxc.has.data.nic() {
  local id="$1"
  awk -F'\t' -v target="${id}" -v bridge="${EXPECTED_DATA_BRIDGE}" 'NR > 1 && $2 == target && $7 == bridge {found=1} END {exit(found ? 0 : 1)}' \
    "${LXC_TSV_PATH}" 2>/dev/null
}

vm.has.data.nic() {
  local id="$1"
  awk -F'\t' -v target="${id}" -v bridge="${EXPECTED_DATA_BRIDGE}" 'NR > 1 && $2 == target && $8 == bridge {found=1} END {exit(found ? 0 : 1)}' \
    "${VM_TSV_PATH}" 2>/dev/null
}

lxc.has.admin.nic() {
  local id="$1"
  awk -F'\t' -v target="${id}" -v bridge="${EXPECTED_ADMIN_BRIDGE}" 'NR > 1 && $2 == target && $7 == bridge {found=1} END {exit(found ? 0 : 1)}' \
    "${LXC_TSV_PATH}" 2>/dev/null
}

lxc.egress.if.name() {
  local id="$1"
  awk -F'\t' -v target="${id}" '
    NR > 1 && $2 == target {
      if ($13 != "" && $13 != "-") { print $6; printed=1; exit }
      if (dhcp == "" && $12 == "dhcp") dhcp=$6
      if (first == "") first=$6
    }
    END {
      if (!printed && dhcp != "") print dhcp
      else if (!printed && first != "") print first
    }
  ' "${LXC_TSV_PATH}" 2>/dev/null | head -n1
}

lxc.guest.if.exists() {
  local id="$1" guest_if="$2"
  awk -F'\t' -v target="${id}" -v guest_if="${guest_if}" \
    'NR > 1 && $2 == target && $6 == guest_if {found=1} END {exit(found ? 0 : 1)}' \
    "${LXC_TSV_PATH}" 2>/dev/null
}

suggest.lxc.data.if.name() {
  local id="$1" number=0 candidate=""
  while ((number < 100)); do
    candidate="eth${number}"
    if ! lxc.guest.if.exists "${id}" "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    number=$((number + 1))
  done
  return 1
}

lxc.net.body.by.slot() {
  local config_path="${1:-}"
  local slot="${2:-}"
  [[ -f "${config_path}" ]] || return 1
  sed -n "s/^${slot}: //p" "${config_path}" 2>/dev/null | head -n1
}

vm.has.any.nic() {
  local id="$1"
  awk -F'\t' -v target="${id}" 'NR > 1 && $2 == target {found=1} END {exit(found ? 0 : 1)}' "${VM_TSV_PATH}" 2>/dev/null
}

candidate.lxc.ids() {
  awk -F'\t' -v data="${EXPECTED_DATA_BRIDGE}" '
    NR > 1 {
      id = $2
      name[id] = $3
      if ($7 == data) has_data[id] = 1
    }
    END {
      for (id in name) {
        if (!has_data[id]) {
          print id
        }
      }
    }
  ' "${LXC_TSV_PATH}" 2>/dev/null | sort -n
}

candidate.vm.ids() {
  awk -F'\t' -v data="${EXPECTED_DATA_BRIDGE}" '
    NR > 1 {
      id = $2
      if (id == "" || id == "-") {
        next
      }
      seen[id] = 1
      if ($8 == data) has_data[id] = 1
    }
    END {
      for (id in seen) {
        if (!has_data[id]) {
          print id
        }
      }
    }
  ' "${VM_TSV_PATH}" 2>/dev/null | sort -n
}

load.update.candidates() {
  UPDATE_LXC_IDS=()
  UPDATE_VM_IDS=()
  local id=""
  while IFS= read -r id; do
    append.unique.id UPDATE_LXC_IDS "${id}"
  done < <(candidate.lxc.ids)
  while IFS= read -r id; do
    append.unique.id UPDATE_VM_IDS "${id}"
  done < <(candidate.vm.ids)
}

resolve.data.ipv4.selection() {
  local candidate="${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR}" normalized="" derived=""
  local interactive=0
  if is.true "${FEATURE_INTERACTIVE}" && ((OPEN_TTY == 1)); then
    interactive=1
  fi

  while true; do
    if ((interactive == 1)); then
      candidate="$(trim.space "$(prompt.tty "Enter static data IPv4 address or CIDR (no gateway; /${PROXMOX_NETWORK_DEFAULT_DATA_PREFIX} assumed when omitted)" "${candidate}")")"
    fi

    if normalized="$(normalize.ipv4.interface.cidr "${candidate}" "${PROXMOX_NETWORK_DEFAULT_DATA_PREFIX}" 2>/dev/null)"; then
      derived="$(derive.ipv4.network.cidr "${normalized}")"
      if ! ipv4.cidrs.overlap "${EXPECTED_MANAGEMENT_CIDR}" "${derived}"; then
        PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR="${normalized}"
        EXPECTED_DATA_CIDR="${derived}"
        if ((interactive == 1)); then
          printf '  container DATA-Link address: %s\n' "${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR}" >&3
          printf '  derived DATA-Link subnet:   %s\n' "${EXPECTED_DATA_CIDR}" >&3
        else
          log "Container DATA-Link address=${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR} derived_subnet=${EXPECTED_DATA_CIDR}"
        fi
        return 0
      fi
      log.error "Data CIDR ${derived} overlaps management CIDR ${EXPECTED_MANAGEMENT_CIDR}."
      log.error "Choose a separate local-only subnet for the SMB DATA-Link network."
    else
      log.error "A usable static IPv4 host address is required; network and broadcast addresses are not assignable."
      log.error "Enter an address such as 10.10.0.4 or 10.10.0.4/24, not the subnet identifier 10.10.0.0/24."
    fi

    if ((interactive == 0)); then
      return 1
    fi
    candidate=""
  done
}

collect.update.selection() {
  local candidate_lxc_csv choice selected_lxc selected_id suggested_data_if
  local interactive=0
  candidate_lxc_csv="$(csv.from.id.list UPDATE_LXC_IDS)"
  UPDATE_VM_IDS=()

  if ! is.true "${FEATURE_INTERACTIVE}" || ! open.tty; then
    if [[ -n "${PROXMOX_NETWORK_UPDATE_LXCS}" ]]; then
      UPDATE_LXC_IDS=()
      while IFS= read -r choice; do
        append.unique.id UPDATE_LXC_IDS "${choice}"
      done < <(parse.id.filter "${PROXMOX_NETWORK_UPDATE_LXCS}")
    elif [[ -n "${CTID_FILTER}" ]]; then
      UPDATE_LXC_IDS=()
      while IFS= read -r choice; do
        append.unique.id UPDATE_LXC_IDS "${choice}"
      done < <(parse.id.filter "${CTID_FILTER}")
    fi
  else
    interactive=1
    printf '\nNetwork update candidate summary:\n' >&3
    printf '  Snapshot: %s\n' "${RUN_DIR}" >&3
    printf '  Candidate LXC IDs missing data NIC: %s\n' "${candidate_lxc_csv:-none}" >&3
    printf '  Discovered/selected data bridge: %s\n' "${EXPECTED_DATA_BRIDGE:-none}" >&3
    printf '\n' >&3

    choice="$(menu.tty "Select update scope:" "selected LXC" "enter one LXC ID" "abort")"
    case "${choice}" in
      1) selected_lxc="$(prompt.tty "Enter LXC ID" "${candidate_lxc_csv%%,*}")" ;;
      2) selected_lxc="$(prompt.tty "Enter LXC ID" "")" ;;
      *) log.error "Aborted by operator."; exit 1 ;;
    esac
    UPDATE_LXC_IDS=()
    while IFS= read -r choice; do
      append.unique.id UPDATE_LXC_IDS "${choice}"
    done < <(parse.id.filter "${selected_lxc}")

    printf '  update-ready data bridge: %s\n' "${EXPECTED_DATA_BRIDGE}" >&3
    if ((${#UPDATE_LXC_IDS[@]} == 1)); then
      selected_id="${UPDATE_LXC_IDS[0]}"
      EXPECTED_GUEST_ADMIN_IF="$(lxc.egress.if.name "${selected_id}")"
      suggested_data_if="$(suggest.lxc.data.if.name "${selected_id}")"
      EXPECTED_GUEST_DATA_IF="$(trim.space "$(prompt.tty "Enter new container data interface name" "${EXPECTED_GUEST_DATA_IF:-${suggested_data_if}}")")"
    fi
  fi

  ((${#UPDATE_LXC_IDS[@]} == 1)) || {
    log.error "The static ingest-network workflow configures exactly one LXC per run."
    exit 1
  }
  selected_id="${UPDATE_LXC_IDS[0]}"
  [[ -n "${EXPECTED_DATA_BRIDGE}" ]] || { log.error "A discovered/operator-selected data bridge is required."; exit 1; }
  ip link show dev "${EXPECTED_DATA_BRIDGE}" >/dev/null 2>&1 || { log.error "Data bridge does not exist: ${EXPECTED_DATA_BRIDGE}"; exit 1; }
  EXPECTED_GUEST_ADMIN_IF="${EXPECTED_GUEST_ADMIN_IF:-$(lxc.egress.if.name "${selected_id}")}"
  [[ -n "${EXPECTED_GUEST_ADMIN_IF}" && "${EXPECTED_GUEST_ADMIN_IF}" != "-" ]] || { log.error "Could not discover the existing LXC egress interface."; exit 1; }
  valid.interface.name "${EXPECTED_GUEST_DATA_IF}" || { log.error "Invalid or missing container data interface name: ${EXPECTED_GUEST_DATA_IF:-empty}"; exit 1; }
  [[ "${EXPECTED_GUEST_DATA_IF}" != "${EXPECTED_GUEST_ADMIN_IF}" ]] || { log.error "Data and egress interface names must differ."; exit 1; }
  ! lxc.guest.if.exists "${selected_id}" "${EXPECTED_GUEST_DATA_IF}" || { log.error "Container interface already exists: ${EXPECTED_GUEST_DATA_IF}"; exit 1; }
  resolve.data.ipv4.selection || exit 1
  [[ "${PROXMOX_NETWORK_UPDATE_LXC_STRATEGY}" == "add_data_nic" ]] || { log.error "Only the non-destructive add_data_nic strategy is supported."; exit 1; }
  PROXMOX_NETWORK_UPDATE_VLAN_TAG=""
  PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS=""

  if ((interactive == 1)); then
    if [[ "${PROXMOX_NETWORK_UPDATE_MODE}" == "apply" ]]; then
      choice="$(menu.tty "Run apply stage after check preview?" "yes" "no")"
      [[ "${choice}" == "2" ]] && PROXMOX_NETWORK_UPDATE_MODE="check"
    else
      choice="$(menu.tty "Update mode:" "check only" "check then apply")"
      [[ "${choice}" == "2" ]] && PROXMOX_NETWORK_UPDATE_MODE="apply"
    fi
  fi
}

build.network.update.plan() {
  local id name conf_path slot desired
  local row_count=0
  set.stage "build.network.update.plan"
  mkdir -p "${FACTS_DIR}"

  printf 'guest_type\tguest_id\tguest_name\tnet_slot\tdesired_value\treason\n' > "${NETWORK_PLAN_PATH}"

  for id in "${UPDATE_LXC_IDS[@]}"; do
    [[ -n "${id}" ]] || continue
    conf_path="${RAW_LXC_DIR}/${id}/config.txt"
    if [[ ! -f "${conf_path}" ]]; then
      mkdir -p "$(dirname "${conf_path}")"
      capture.cmd "${conf_path}" "pct config ${id}" "pct config ${id}"
    fi
    name="$(awk -F'\t' -v target="${id}" 'NR > 1 && $2 == target {print $3; exit}' "${LXC_TSV_PATH}" 2>/dev/null || true)"
    [[ -n "${name}" ]] || name="ct${id}"

    if lxc.has.data.nic "${id}"; then
      log "Skipping LXC ${id}: already has a data NIC on ${EXPECTED_DATA_BRIDGE}."
      continue
    fi
    slot="$(pick.free.net.slot "${conf_path}")"
    if [[ -z "${slot}" ]]; then
      log.warn "Skipping LXC ${id}: no free net slot from net1..net9."
      continue
    fi
    desired="name=${EXPECTED_GUEST_DATA_IF},bridge=${EXPECTED_DATA_BRIDGE},firewall=1,ip=${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR}"
    append.tsv.row "${NETWORK_PLAN_PATH}" "lxc" "${id}" "${name}" "${slot}" "${desired}" "add_static_data_role_no_gateway"
    row_count=$((row_count + 1))
  done

  for id in "${UPDATE_VM_IDS[@]}"; do
    [[ -n "${id}" ]] || continue
    if ! vm.has.any.nic "${id}"; then
      log.warn "Skipping VM ${id}: no existing NIC rows in snapshot."
      continue
    fi
    if vm.has.data.nic "${id}"; then
      log "Skipping VM ${id}: already has a data NIC on ${EXPECTED_DATA_BRIDGE}."
      continue
    fi
    conf_path="${RAW_VM_DIR}/${id}/config.txt"
    if [[ ! -f "${conf_path}" ]]; then
      mkdir -p "$(dirname "${conf_path}")"
      capture.cmd "${conf_path}" "qm config ${id}" "qm config ${id}"
    fi
    slot="$(pick.free.net.slot "${conf_path}")"
    if [[ -z "${slot}" ]]; then
      log.warn "Skipping VM ${id}: no free net slot from net1..net9."
      continue
    fi
    name="$(awk -F'\t' -v target="${id}" 'NR > 1 && $2 == target {print $3; exit}' "${VM_TSV_PATH}" 2>/dev/null || true)"
    [[ -n "${name}" ]] || name="vm${id}"
    desired="${PROXMOX_NETWORK_UPDATE_VM_MODEL},bridge=${EXPECTED_DATA_BRIDGE}"
    if [[ -n "${PROXMOX_NETWORK_UPDATE_VLAN_TAG}" ]]; then
      desired="${desired},tag=${PROXMOX_NETWORK_UPDATE_VLAN_TAG}"
    elif [[ -n "${PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS}" ]]; then
      desired="${desired},trunks=${PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS}"
    fi
    append.tsv.row "${NETWORK_PLAN_PATH}" "vm" "${id}" "${name}" "${slot}" "${desired}" "missing_data_nic"
    row_count=$((row_count + 1))
  done

  if [[ "${row_count}" -eq 0 ]]; then
    log.warn "No guest network updates were planned from snapshot ${RUN_DIR}."
  else
    log "Built network update plan: ${NETWORK_PLAN_PATH} (${row_count} rows)"
  fi
}

write.network.intent.file() {
  set.stage "write.network.intent.file"
  local lxc_csv vm_csv
  lxc_csv="$(csv.from.id.list UPDATE_LXC_IDS)"
  vm_csv="$(csv.from.id.list UPDATE_VM_IDS)"
  mkdir -p "${FACTS_DIR}"

  cat > "${NETWORK_INTENT_PATH}" <<EOF
---
proxmox_network_update:
  snapshot_dir: $(yaml.quote "${RUN_DIR}")
  mode: $(yaml.quote "${PROXMOX_NETWORK_UPDATE_MODE}")
  expected:
    admin_bridge: $(yaml.quote "${EXPECTED_ADMIN_BRIDGE}")
    data_bridge: $(yaml.quote "${EXPECTED_DATA_BRIDGE}")
    data_link_mode: $(yaml.quote "${EXPECTED_DATA_LINK_MODE}")
    management_cidr: $(yaml.quote "${EXPECTED_MANAGEMENT_CIDR}")
    data_cidr: $(yaml.quote "${EXPECTED_DATA_CIDR}")
    guest_admin_if: $(yaml.quote "${EXPECTED_GUEST_ADMIN_IF}")
    guest_data_if: $(yaml.quote "${EXPECTED_GUEST_DATA_IF}")
    data_ipv4_cidr: $(yaml.quote "${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR}")
  selected:
    lxc_ids_csv: $(yaml.quote "${lxc_csv}")
    vm_ids_csv: $(yaml.quote "${vm_csv}")
    lxc_strategy: $(yaml.quote "${PROXMOX_NETWORK_UPDATE_LXC_STRATEGY}")
    vlan_tag: $(yaml.quote "${PROXMOX_NETWORK_UPDATE_VLAN_TAG}")
    vlan_trunks: $(yaml.quote "${PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS}")
    vm_model: $(yaml.quote "${PROXMOX_NETWORK_UPDATE_VM_MODEL}")
  artifacts:
    preflight_facts_yml: $(yaml.quote "${ANSIBLE_PREFLIGHT_FACTS_YAML}")
    preflight_facts_json: $(yaml.quote "${ANSIBLE_PREFLIGHT_FACTS_JSON}")
    plan_tsv: $(yaml.quote "${NETWORK_PLAN_PATH}")
    verify_tsv: $(yaml.quote "${NETWORK_VERIFY_PATH}")
    transaction_tsv: $(yaml.quote "${NETWORK_TRANSACTION_PATH}")
    rollback_tsv: $(yaml.quote "${NETWORK_ROLLBACK_PATH}")
EOF
}

write.network.update.status() {
  local status="${1:-unknown}" phase="${2:-unknown}" detail="${3:-}"
  mkdir -p "${FACTS_DIR}"
  cat > "${NETWORK_UPDATE_STATUS_PATH}" <<EOF
---
proxmox_network_update_status:
  status: $(yaml.quote "${status}")
  phase: $(yaml.quote "${phase}")
  detail: $(yaml.quote "${detail}")
  snapshot_dir: $(yaml.quote "${RUN_DIR}")
  plan_path: $(yaml.quote "${NETWORK_PLAN_PATH}")
  intent_path: $(yaml.quote "${NETWORK_INTENT_PATH}")
  verify_path: $(yaml.quote "${NETWORK_VERIFY_PATH}")
  transaction_path: $(yaml.quote "${NETWORK_TRANSACTION_PATH}")
  rollback_path: $(yaml.quote "${NETWORK_ROLLBACK_PATH}")
  recovery_mode: $(yaml.quote "${NETWORK_RECOVERY_MODE}")
  rollback_outcome: $(yaml.quote "${NETWORK_ROLLBACK_OUTCOME}")
  normalized_data_ipv4_cidr: $(yaml.quote "${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR}")
  derived_data_cidr: $(yaml.quote "${EXPECTED_DATA_CIDR}")
EOF
}

write.network.extra.vars.file() {
  local mode="${1:-check}"
  local apply_requested="false"
  if [[ "${mode}" == "apply" ]]; then
    apply_requested="true"
  fi
  set.stage "write.network.extra.vars.file"
  mkdir -p "${TMP_DIR}"
  cat > "${NETWORK_EXTRA_VARS_PATH}" <<EOF
---
proxmox_network_run_dir: $(yaml.quote "${RUN_DIR}")
proxmox_network_facts_dir: $(yaml.quote "${FACTS_DIR}")
proxmox_network_preflight_facts_path: $(yaml.quote "${ANSIBLE_PREFLIGHT_FACTS_YAML}")
proxmox_network_preflight_json_path: $(yaml.quote "${ANSIBLE_PREFLIGHT_FACTS_JSON}")
proxmox_network_intent_path: $(yaml.quote "${NETWORK_INTENT_PATH}")
proxmox_network_plan_path: $(yaml.quote "${NETWORK_PLAN_PATH}")
proxmox_network_verify_path: $(yaml.quote "${NETWORK_VERIFY_PATH}")
proxmox_network_update_runtime_facts_path: $(yaml.quote "${NETWORK_UPDATE_RUNTIME_FACTS_PATH}")
proxmox_network_lxc_nic_helper_path: $(yaml.quote "${NETWORK_LXC_NIC_HELPER_PATH}")
proxmox_network_update_mode: $(yaml.quote "${mode}")
proxmox_network_expected_admin_bridge: $(yaml.quote "${EXPECTED_ADMIN_BRIDGE}")
proxmox_network_expected_data_bridge: $(yaml.quote "${EXPECTED_DATA_BRIDGE}")
proxmox_network_management_cidr: $(yaml.quote "${EXPECTED_MANAGEMENT_CIDR}")
proxmox_network_data_cidr: $(yaml.quote "${EXPECTED_DATA_CIDR}")
proxmox_network_expected_guest_egress_if: $(yaml.quote "${EXPECTED_GUEST_ADMIN_IF}")
proxmox_network_expected_guest_data_if: $(yaml.quote "${EXPECTED_GUEST_DATA_IF}")
proxmox_network_expected_data_ipv4_cidr: $(yaml.quote "${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR}")
proxmox_network_update_apply_requested: ${apply_requested}
EOF
}

network.status.field() {
  local key="${1:-}"
  [[ -f "${NETWORK_UPDATE_STATUS_PATH}" && -n "${key}" ]] || return 1
  sed -n "s/^[[:space:]]*${key}: \"\(.*\)\"$/\1/p" "${NETWORK_UPDATE_STATUS_PATH}" | head -n1
}

lxc.nic.semantic.compare() {
  local expected="${1:-}" actual="${2:-}"
  python3 "${NETWORK_LXC_NIC_HELPER_PATH}" compare --expected "${expected}" --actual "${actual}"
}

guest.net.value() {
  local guest_type="${1:-}" guest_id="${2:-}" net_slot="${3:-}"
  if [[ "${guest_type}" == "lxc" ]]; then
    pct config "${guest_id}" 2>/dev/null | sed -n "s/^${net_slot}: //p" | head -n1 || true
  elif [[ "${guest_type}" == "vm" ]]; then
    qm config "${guest_id}" 2>/dev/null | sed -n "s/^${net_slot}: //p" | head -n1 || true
  fi
}

write.network.transaction.journal() {
  local mode="${1:-new}"
  local guest_type guest_id guest_name net_slot desired_value reason current_value comparison
  local errors=0
  printf 'guest_type\tguest_id\tguest_name\tnet_slot\tpre_state\tpre_value\tdesired_value\n' > "${NETWORK_TRANSACTION_PATH}"

  while IFS=$'\t' read -r guest_type guest_id guest_name net_slot desired_value reason; do
    [[ "${guest_type}" != "guest_type" ]] || continue
    current_value="$(guest.net.value "${guest_type}" "${guest_id}" "${net_slot}")"
    if [[ "${mode}" == "new" && -n "${current_value}" ]]; then
      log.error "Transaction refused: ${guest_type} ${guest_id} ${net_slot} became occupied before apply."
      errors=$((errors + 1))
      continue
    fi
    if [[ "${mode}" == "recovery" ]]; then
      if [[ "${guest_type}" != "lxc" ]]; then
        log.error "Recovery is supported only for the LXC DATA-Link workflow."
        errors=$((errors + 1))
        continue
      fi
      if ! comparison="$(lxc.nic.semantic.compare "${desired_value}" "${current_value}" 2>&1)"; then
        log.error "Recovery conflict for LXC ${guest_id} ${net_slot}: ${comparison}"
        errors=$((errors + 1))
        continue
      fi
    fi
    append.tsv.row "${NETWORK_TRANSACTION_PATH}" \
      "${guest_type}" "${guest_id}" "${guest_name}" "${net_slot}" "absent" "-" "${desired_value}"
  done < "${NETWORK_PLAN_PATH}"

  [[ "${errors}" -eq 0 ]]
}

detect.pending.network.recovery() {
  local status phase row_count guest_type guest_id guest_name net_slot desired_value reason
  local current_value comparison choice desired_if desired_bridge desired_ip
  status="$(network.status.field status || true)"
  phase="$(network.status.field phase || true)"
  [[ "${status}" == "failed" ]] || return 1
  case "${phase}" in
    apply|verify|runtime|post-apply-preflight|recovery-check-export|recovery-check-preview|recovery-journal) ;;
    *) return 1 ;;
  esac
  [[ -f "${NETWORK_PLAN_PATH}" ]] || return 1
  row_count="$(tsv.data.row.count "${NETWORK_PLAN_PATH}" 2>/dev/null || printf '0')"
  [[ "${row_count}" -eq 1 ]] || {
    log.error "Cannot automatically recover a failed network plan with ${row_count} rows."
    return 2
  }

  IFS=$'\t' read -r guest_type guest_id guest_name net_slot desired_value reason < <(awk 'NR == 2 {print; exit}' "${NETWORK_PLAN_PATH}")
  [[ "${guest_type}" == "lxc" && -n "${guest_id}" && -n "${net_slot}" && -n "${desired_value}" ]] || {
    log.error "The failed network plan is not a recoverable single-LXC DATA-Link update."
    return 2
  }
  current_value="$(guest.net.value "${guest_type}" "${guest_id}" "${net_slot}")"
  [[ -n "${current_value}" ]] || return 1
  if ! comparison="$(lxc.nic.semantic.compare "${desired_value}" "${current_value}" 2>&1)"; then
    log.error "Pending network recovery conflicts with live LXC ${guest_id} ${net_slot}: ${comparison}"
    log.error "No interface was changed. Review pct config ${guest_id} and ${NETWORK_PLAN_PATH}."
    return 2
  fi

  desired_if="$(extract.csv.kv "${desired_value}" name || true)"
  desired_bridge="$(extract.csv.kv "${desired_value}" bridge || true)"
  desired_ip="$(extract.csv.kv "${desired_value}" ip || true)"
  [[ -n "${desired_if}" && -n "${desired_bridge}" && -n "${desired_ip}" ]] || {
    log.error "The pending recovery plan does not contain a complete LXC DATA-Link identity."
    return 2
  }
  [[ "${desired_bridge}" == "${EXPECTED_DATA_BRIDGE}" ]] || {
    log.error "Pending recovery bridge ${desired_bridge} differs from live selected bridge ${EXPECTED_DATA_BRIDGE}."
    return 2
  }

  UPDATE_LXC_IDS=("${guest_id}")
  UPDATE_VM_IDS=()
  EXPECTED_GUEST_ADMIN_IF="$(lxc.egress.if.name "${guest_id}")"
  EXPECTED_GUEST_DATA_IF="${desired_if}"
  PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR="${desired_ip}"
  EXPECTED_DATA_CIDR="$(derive.ipv4.network.cidr "${desired_ip}")"
  [[ -n "${EXPECTED_GUEST_ADMIN_IF}" ]] || {
    log.error "Could not resolve the preserved management interface for recovery LXC ${guest_id}."
    return 2
  }

  if is.true "${FEATURE_INTERACTIVE}" && open.tty; then
    printf '\nRecoverable DATA-Link update detected:\n' >&3
    printf '  LXC:              %s\n' "${guest_id}" >&3
    printf '  existing slot:    %s\n' "${net_slot}" >&3
    printf '  data interface:   %s\n' "${desired_if}" >&3
    printf '  data bridge:      %s\n' "${desired_bridge}" >&3
    printf '  data address:     %s\n' "${desired_ip}" >&3
    printf '  failed phase:     %s\n' "${phase}" >&3
    choice="$(menu.tty "Resume semantic verification and runtime completion?" "yes" "abort")"
    [[ "${choice}" == "1" ]] || return 2
  elif [[ "${PROXMOX_NETWORK_UPDATE_MODE}" != "apply" ]] && ! is.true "${PROXMOX_NETWORK_UPDATE_AUTO_APPLY}"; then
    log.error "A matching pending update exists. Set PROXMOX_NETWORK_UPDATE_MODE=apply to resume non-interactively."
    return 2
  fi

  NETWORK_RECOVERY_MODE=1
  PROXMOX_NETWORK_UPDATE_MODE="apply"
  log "Resuming the matching LXC DATA-Link update without reassigning or overwriting ${net_slot}."
  return 0
}

rollback.network.update.plan() {
  local guest_type guest_id guest_name net_slot pre_state pre_value desired_value current_value comparison status detail
  local deleted=0 absent=0 conflicts=0 errors=0
  log.warn "Rolling back NICs added by the failed network apply/verify stage."
  printf 'guest_type\tguest_id\tguest_name\tnet_slot\tdesired_value\tactual_value\tstatus\tdetail\n' > "${NETWORK_ROLLBACK_PATH}"
  if [[ ! -f "${NETWORK_TRANSACTION_PATH}" ]]; then
    NETWORK_ROLLBACK_OUTCOME="missing-transaction"
    log.error "Rollback journal is missing: ${NETWORK_TRANSACTION_PATH}"
    return 1
  fi

  while IFS=$'\t' read -r guest_type guest_id guest_name net_slot pre_state pre_value desired_value; do
    [[ "${guest_type}" != "guest_type" ]] || continue
    current_value="$(guest.net.value "${guest_type}" "${guest_id}" "${net_slot}")"
    status="already_absent"
    detail="slot is already absent"
    if [[ "${pre_state}" != "absent" ]]; then
      status="conflict"
      detail="transaction did not record an originally absent slot"
      conflicts=$((conflicts + 1))
    elif [[ -z "${current_value}" ]]; then
      absent=$((absent + 1))
    elif [[ "${guest_type}" == "lxc" ]]; then
      if comparison="$(lxc.nic.semantic.compare "${desired_value}" "${current_value}" 2>&1)"; then
        if pct set "${guest_id}" -delete "${net_slot}"; then
          status="deleted"
          detail="semantically matching feature-owned NIC was removed"
          deleted=$((deleted + 1))
        else
          status="error"
          detail="pct failed to delete the matching feature-owned NIC"
          errors=$((errors + 1))
        fi
      else
        status="conflict"
        detail="live NIC differs from the transaction: ${comparison}"
        conflicts=$((conflicts + 1))
      fi
    elif [[ "${guest_type}" == "vm" ]]; then
      if [[ "${current_value}" == "${desired_value}" ]]; then
        if qm set "${guest_id}" -delete "${net_slot}"; then
          status="deleted"
          detail="exactly matching feature-owned VM NIC was removed"
          deleted=$((deleted + 1))
        else
          status="error"
          detail="qm failed to delete the matching feature-owned NIC"
          errors=$((errors + 1))
        fi
      else
        status="conflict"
        detail="live VM NIC differs from the transaction"
        conflicts=$((conflicts + 1))
      fi
    else
      status="error"
      detail="unsupported guest type=${guest_type}"
      errors=$((errors + 1))
    fi
    append.tsv.row "${NETWORK_ROLLBACK_PATH}" \
      "${guest_type}" "${guest_id}" "${guest_name}" "${net_slot}" "${desired_value}" "${current_value:--}" "${status}" "${detail}"
  done < "${NETWORK_TRANSACTION_PATH}"

  if ((conflicts > 0 || errors > 0)); then
    NETWORK_ROLLBACK_OUTCOME="incomplete:deleted=${deleted},absent=${absent},conflicts=${conflicts},errors=${errors}"
    log.error "Rollback incomplete; see ${NETWORK_ROLLBACK_PATH}. ${NETWORK_ROLLBACK_OUTCOME}"
    return 1
  fi
  NETWORK_ROLLBACK_OUTCOME="complete:deleted=${deleted},absent=${absent}"
  log "Rollback completed safely. ${NETWORK_ROLLBACK_OUTCOME}"
  return 0
}

record.network.failure.with.rollback() {
  local phase="${1:-unknown}" detail="${2:-Network update failed.}"
  if rollback.network.update.plan; then
    write.network.update.status "failed" "${phase}" "${detail} Rollback completed safely."
  else
    write.network.update.status "failed" "${phase}" "${detail} Rollback is incomplete; inspect ${NETWORK_ROLLBACK_PATH}."
  fi
}

lxc.runtime.data.ready() {
  local id="$1" addr_output route_output
  addr_output="$(pct exec "${id}" -- ip -o -4 addr show dev "${EXPECTED_GUEST_DATA_IF}" 2>/dev/null || true)"
  route_output="$(pct exec "${id}" -- ip -4 route show default 2>/dev/null || true)"
  printf '%s\n' "${addr_output}" | awk -v expected="${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR}" '$4 == expected {found=1} END {exit(found ? 0 : 1)}' \
    || return 1
  printf '%s\n' "${route_output}" | awk -v expected_if="${EXPECTED_GUEST_ADMIN_IF}" '
    /^default / {
      count += 1
      for (i = 1; i < NF; i += 1) if ($i == "dev" && $(i + 1) == expected_if) matched=1
    }
    END {exit(count == 1 && matched ? 0 : 1)}
'
}

wait.lxc.runtime.data() {
  local id="$1" attempt
  for attempt in {1..20}; do
    lxc.runtime.data.ready "${id}" && return 0
    sleep 1
  done
  return 1
}

ensure.lxc.runtime.data.role() {
  local id status choice restart_allowed=0
  for id in "${UPDATE_LXC_IDS[@]}"; do
    status="$(pct status "${id}" 2>/dev/null | awk '{print $2}')"
    if [[ "${status}" != running ]]; then
      log "LXC ${id} is stopped; the verified data NIC will activate on its next operator-controlled start."
      continue
    fi
    if wait.lxc.runtime.data "${id}"; then
      log "LXC ${id} hot-applied ${EXPECTED_GUEST_DATA_IF}=${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR} and preserved its sole default route on ${EXPECTED_GUEST_ADMIN_IF}."
      continue
    fi

    log.warn "LXC ${id} config is updated, but runtime interface/address verification is still pending."
    is.true "${PROXMOX_NETWORK_ALLOW_LXC_RESTART}" && restart_allowed=1
    if is.true "${FEATURE_INTERACTIVE}" && open.tty; then
      choice="$(menu.tty "Restart LXC ${id} now to activate the verified data NIC?" "no (rollback the new NIC)" "yes")"
      [[ "${choice}" == 2 ]] && restart_allowed=1
    fi
    if ((restart_allowed == 0)); then
      log.error "Runtime activation was not authorized; the newly added NIC will be rolled back."
      return 1
    fi

    log "Restarting LXC ${id} because runtime evidence proved hot-apply incomplete."
    pct reboot "${id}" || return 1
    if ! wait.lxc.runtime.data "${id}"; then
      log.error "LXC ${id} did not return with the expected data role and sole egress default route."
      return 1
    fi
    log "LXC ${id} restart verification passed."
  done
}

run.network.update.flow() {
  local apply_requested=0 choice prev_interactive recovery_rc=0

  resolve.snapshot.dir
  load.snapshot.defaults
  require.snapshot.artifacts
  require.live.update.topology
  ensure.network.ansible
  prepare.feature.files

  if detect.pending.network.recovery; then
    apply_requested=1
  else
    recovery_rc=$?
    if [[ "${recovery_rc}" -ne 1 ]]; then
      return 1
    fi
    load.update.candidates
    collect.update.selection
    require.live.update.topology
    if ! probe.data.ip.conflict; then
      write.network.update.status "failed" "initial-address-probe" "Duplicate-address validation failed before plan generation; no guest mutation was attempted."
      return 1
    fi
    build.network.update.plan
    if ! awk 'NR > 1 {found=1} END {exit(found ? 0 : 1)}' "${NETWORK_PLAN_PATH}" 2>/dev/null; then
      log.warn "No actionable plan rows found. Update stage exiting without changes."
      return 0
    fi

    write.network.intent.file
    write.network.update.status "prepared" "plan" "Validated plan is ready for check mode."
  fi
  log "Network update scope is limited to guest NIC config. Samba hardening stays in a separate script."

  write.network.extra.vars.file "check"
  set.stage "check.export.preflight.facts"
  if ! run.feature.playbook "${NETWORK_EXPORT_PLAYBOOK_PATH}" -e "@${NETWORK_EXTRA_VARS_PATH}"; then
    if [[ "${NETWORK_RECOVERY_MODE}" -eq 1 ]]; then
      write.network.update.status "failed" "recovery-check-export" "Recovery preflight fact export failed; the existing matching NIC was preserved."
    else
      write.network.update.status "failed" "check-export" "Preflight fact export failed; no guest mutation was attempted."
    fi
    return 1
  fi
  set.stage "check.preview.network.update"
  if ! run.feature.playbook "${NETWORK_UPDATE_PLAYBOOK_PATH}" -e "@${NETWORK_EXTRA_VARS_PATH}"; then
    if [[ "${NETWORK_RECOVERY_MODE}" -eq 1 ]]; then
      write.network.update.status "failed" "recovery-check-preview" "Recovery semantic preview failed; the existing matching NIC was preserved."
    else
      write.network.update.status "failed" "check-preview" "Check-mode preview failed; no guest mutation was attempted."
    fi
    return 1
  fi
  if [[ "${NETWORK_RECOVERY_MODE}" -eq 0 ]]; then
    write.network.update.status "checked" "check-preview" "Check-mode preview passed without guest mutation."
  fi

  if [[ "${NETWORK_RECOVERY_MODE}" -eq 1 ]] \
    || [[ "${PROXMOX_NETWORK_UPDATE_MODE}" == "apply" ]] \
    || is.true "${PROXMOX_NETWORK_UPDATE_AUTO_APPLY}"; then
    apply_requested=1
  fi

  if [[ "${apply_requested}" -eq 0 ]]; then
    if is.true "${FEATURE_INTERACTIVE}" && open.tty; then
      choice="$(menu.tty "Apply guest network plan now?" "no" "yes")"
      if [[ "${choice}" == "2" ]]; then
        apply_requested=1
      fi
    fi
  fi

  if [[ "${apply_requested}" -eq 0 ]]; then
    log "Update check phase complete. No apply requested."
    return 0
  fi

  require.live.update.topology
  if [[ "${NETWORK_RECOVERY_MODE}" -eq 1 ]]; then
    log "Skipping duplicate-address reprobe because the matching selected LXC already owns ${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR}."
    if ! write.network.transaction.journal recovery; then
      write.network.update.status "failed" "recovery-journal" "Could not prove ownership of the existing DATA-Link NIC; no mutation was attempted."
      return 1
    fi
  else
    if ! probe.data.ip.conflict; then
      write.network.update.status "failed" "pre-apply-address-probe" "Duplicate-address revalidation failed immediately before apply; no guest mutation was attempted."
      return 1
    fi
    if ! write.network.transaction.journal new; then
      write.network.update.status "failed" "pre-apply-journal" "A selected guest slot changed after preview; no guest mutation was attempted."
      return 1
    fi
    write.network.update.status "applying" "apply" "Duplicate-address revalidation passed; transaction journaling passed; apply is starting."
  fi
  write.network.extra.vars.file "apply"
  set.stage "apply.network.update"
  if ! run.feature.playbook "${NETWORK_UPDATE_PLAYBOOK_PATH}" -e "@${NETWORK_EXTRA_VARS_PATH}"; then
    record.network.failure.with.rollback "apply" "Apply failed."
    return 1
  fi
  set.stage "verify.network.update"
  if ! run.feature.playbook "${NETWORK_VERIFY_PLAYBOOK_PATH}" -e "@${NETWORK_EXTRA_VARS_PATH}"; then
    record.network.failure.with.rollback "verify" "Semantic configuration verification failed."
    return 1
  fi
  if ! ensure.lxc.runtime.data.role; then
    record.network.failure.with.rollback "runtime" "Runtime activation or route verification failed."
    return 1
  fi

  log "Apply phase complete. Running post-apply preflight snapshot."
  prev_interactive="${FEATURE_INTERACTIVE}"
  FEATURE_INTERACTIVE=0
  if ! run.preflight; then
    FEATURE_INTERACTIVE="${prev_interactive}"
    record.network.failure.with.rollback "post-apply-preflight" "Post-apply preflight failed."
    return 1
  fi
  FEATURE_INTERACTIVE="${prev_interactive}"
  NETWORK_ROLLBACK_OUTCOME="not-required"
  write.network.update.status "applied" "complete" "Apply, verification, runtime activation, and post-apply preflight passed."
}

maybe.prompt.run.stage() {
  local choice=""
  if [[ "${CLI_ARG_COUNT}" -gt 0 ]]; then
    return 0
  fi
  if ! is.true "${FEATURE_INTERACTIVE}" || ! open.tty; then
    return 0
  fi

  choice="$(menu.tty "Select setup/network stage:" "preflight: collect facts" "update: config network" "report latest" "abort")"
  case "${choice}" in
    1) FEATURE_MODE="preflight" ;;
    2) FEATURE_MODE="update" ;;
    3) FEATURE_MODE="report" ;;
    *) log.error "Aborted by operator."; exit 1 ;;
  esac
}

run.all.flow() {
  local choice=""
  run.preflight

  if ! is.true "${FEATURE_INTERACTIVE}" || ! open.tty; then
    return 0
  fi

  choice="$(menu.tty "Preflight finished. Continue to update stage?" "no" "yes")"
  if [[ "${choice}" == "2" ]]; then
    FEATURE_MODE="update"
    run.network.update.flow
  fi
}

run.preflight() {
  PREFLIGHT_ACTIVE=1
  if [[ "${FEATURE_MODE}" == "debug" ]]; then
    FEATURE_DEBUG=1
    FEATURE_MODE="preflight"
  fi
  discover.basic.host.facts
  discover.available.ct.ids
  discover.available.vm.ids
  collect.operator.selection

  init.run.dir
  enable.debug.trace
  collect.host.raw
  discover.ct.ids
  discover.vm.ids
  collect.guest.raw
  collect.nics.tsv
  collect.bridges.tsv
  classify.host.risks
  collect.vlans.tsv
  log "Selected scope: LXC IDs=$(join.by ',' "${CT_IDS[@]}") VM IDs=$(join.by ',' "${VM_IDS[@]}")"
  collect.lxc.data
  collect.vm.data
  validate.collection.artifacts
  evaluate.snapshot.readiness
  write.host.yaml
  write.snapshot.status
  write.summary
  update.latest.report.pointer

  if [[ "${SNAPSHOT_READY_FOR_UPDATE}" == "true" ]]; then
    write.next.stage.env
    export.preflight.facts.for.ansible
    mark.snapshot.ready
    update.latest.ready.pointer
    write.summary
    PREFLIGHT_ACTIVE=0
    log "Preflight complete and update-ready. Saved network snapshot to ${RUN_DIR}"
    cat "${SUMMARY_PATH}"
    return 0
  fi

  PREFLIGHT_ACTIVE=0
  log.error "Preflight completed but is not update-ready: ${SNAPSHOT_BLOCKING_CODES:-unknown}"
  cat "${SUMMARY_PATH}"
  trap - ERR
  return 2
}

resolve.report.dir() {
  local resolved=""
  if [[ -n "${REPORT_DIR_OVERRIDE}" ]]; then
    resolved="${REPORT_DIR_OVERRIDE}"
  elif [[ -L "${OUTPUT_ROOT}/latest-report" ]]; then
    resolved="$(readlink "${OUTPUT_ROOT}/latest-report")"
    if [[ "${resolved}" != /* ]]; then
      resolved="${OUTPUT_ROOT}/${resolved}"
    fi
  elif [[ -f "${OUTPUT_ROOT}/latest.path" ]]; then
    resolved="$(cat "${OUTPUT_ROOT}/latest.path")"
  fi

  if [[ -z "${resolved}" || ! -d "${resolved}" ]]; then
    log.error "No saved preflight report directory found."
    log.error "Run ./setup/network.sh preflight first, or set PROXMOX_NETWORK_REPORT_DIR."
    exit 1
  fi

  RUN_DIR="${resolved}"
  set.run.paths.from.dir
}

run.report() {
  resolve.report.dir
  if [[ ! -f "${SUMMARY_PATH}" ]]; then
    log.error "Missing summary file: ${SUMMARY_PATH}"
    exit 1
  fi
  cat "${SUMMARY_PATH}"
}

main() {
  install.runtime.traps
  maybe.prompt.run.stage
  require.valid.mode

  case "${FEATURE_MODE}" in
    preflight|debug)
      require.root
      require.proxmox
      require.commands
      run.preflight
      ;;
    update)
      require.root
      require.proxmox
      require.update.commands
      run.network.update.flow
      ;;
    all)
      require.root
      require.proxmox
      require.commands
      require.update.commands
      run.all.flow
      ;;
    report)
      run.report
      ;;
    run)
      require.root
      require.proxmox
      require.commands
      run.preflight
      ;;
  esac
}

if [[ "${PROXMOX_NETWORK_SOURCE_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
