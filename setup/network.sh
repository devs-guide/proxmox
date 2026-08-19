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
EXPECTED_ADMIN_BRIDGE="${PROXMOX_NETWORK_EXPECTED_ADMIN_BRIDGE:-vmbr0}"
EXPECTED_DATA_BRIDGE="${PROXMOX_NETWORK_EXPECTED_DATA_BRIDGE:-vmbr1}"
EXPECTED_LAN_CIDR="${PROXMOX_NETWORK_EXPECTED_LAN_CIDR:-10.0.0.0/24}"
EXPECTED_GUEST_ADMIN_IF="${PROXMOX_NETWORK_EXPECTED_GUEST_ADMIN_IF:-eth0}"
EXPECTED_GUEST_DATA_IF="${PROXMOX_NETWORK_EXPECTED_GUEST_DATA_IF:-eth1}"
CTID_FILTER="${PROXMOX_NETWORK_CTIDS:-}"
VMID_FILTER="${PROXMOX_NETWORK_VMIDS:-}"
FEATURE_INTERACTIVE="${PROXMOX_NETWORK_INTERACTIVE:-1}"
FEATURE_DEBUG="${PROXMOX_NETWORK_DEBUG:-0}"
PROXMOX_NETWORK_UPDATE_MODE="${PROXMOX_NETWORK_UPDATE_MODE:-check}"
PROXMOX_NETWORK_UPDATE_AUTO_APPLY="${PROXMOX_NETWORK_UPDATE_AUTO_APPLY:-0}"
PROXMOX_NETWORK_UPDATE_VLAN_TAG="${PROXMOX_NETWORK_UPDATE_VLAN_TAG-1}"
PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS="${PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS:-}"
PROXMOX_NETWORK_UPDATE_VM_MODEL="${PROXMOX_NETWORK_UPDATE_VM_MODEL:-virtio}"
PROXMOX_NETWORK_UPDATE_LXCS="${PROXMOX_NETWORK_UPDATE_LXCS:-}"
PROXMOX_NETWORK_UPDATE_VMS="${PROXMOX_NETWORK_UPDATE_VMS:-}"
PROXMOX_NETWORK_UPDATE_LXC_STRATEGY="${PROXMOX_NETWORK_UPDATE_LXC_STRATEGY:-highspeed_only}"

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
NETWORK_EXPORT_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[0]}"
NETWORK_UPDATE_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[1]}"
NETWORK_VERIFY_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[2]}"
NETWORK_EXPORT_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${NETWORK_EXPORT_PLAYBOOK_REL}"
NETWORK_UPDATE_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${NETWORK_UPDATE_PLAYBOOK_REL}"
NETWORK_VERIFY_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${NETWORK_VERIFY_PLAYBOOK_REL}"
NETWORK_EXPORT_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_EXPORT_PLAYBOOK_REL}"
NETWORK_UPDATE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_UPDATE_PLAYBOOK_REL}"
NETWORK_VERIFY_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_VERIFY_PLAYBOOK_REL}"
NETWORK_EXTRA_VARS_PATH="${TMP_DIR}/network.update.extra-vars.yml"
ANSIBLE_VENV="/opt/ansible-venv"
ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
ANSIBLE_CORE_VERSION="${PROXMOX_BOOTSTRAP_ANSIBLE_CORE_VERSION:-2.20.5}"
ANSIBLE_CORE_SPEC="ansible-core==${ANSIBLE_CORE_VERSION}"
PYTHON_VERSION="${PROXMOX_BOOTSTRAP_PYTHON_VERSION:-3.12.3}"
PYTHON_MAJOR_MINOR="${PYTHON_VERSION%.*}"
PYTHON_SOURCE_PREFIX="${PROXMOX_BOOTSTRAP_PYTHON_SOURCE_PREFIX:-/usr/local}"
PYTHON_BIN="${PYTHON_SOURCE_PREFIX}/bin/python${PYTHON_MAJOR_MINOR}"
PYTHON_SRC_DIR="${PYTHON_SOURCE_PREFIX}/src/Python-${PYTHON_VERSION}"
PYTHON_SRC_ARCHIVE="${PYTHON_SRC_DIR}.tgz"
PYTHON_SRC_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"
MANAGED_TARGET_PYTHON_HOME="${PROXMOX_BOOTSTRAP_MANAGED_TARGET_PYTHON_HOME:-/opt/ansible/py312}"
MANAGED_TARGET_PYTHON_PATH="${MANAGED_TARGET_PYTHON_HOME}/bin/python"
MANAGED_TARGET_HANDOFF_MARKER="${MANAGED_TARGET_PYTHON_HOME}/.handoff-ready"
PYTHON_BOOTSTRAP_BIN=""
COMMON_HELPER_SOURCED=0

FACTS_DIR="${PROXMOX_NETWORK_FACTS_DIR:-/etc/ansible/proxmox/facts}"
ANSIBLE_PREFLIGHT_FACTS_YAML="${PROXMOX_NETWORK_PREFLIGHT_FACTS_YAML:-${FACTS_DIR}/network.preflight.latest.yml}"
ANSIBLE_PREFLIGHT_FACTS_JSON="${PROXMOX_NETWORK_PREFLIGHT_FACTS_JSON:-${FACTS_DIR}/network.preflight.latest.json}"
NETWORK_INTENT_PATH="${PROXMOX_NETWORK_INTENT_PATH:-${FACTS_DIR}/network.intent.yml}"
NETWORK_PLAN_PATH="${PROXMOX_NETWORK_PLAN_PATH:-${FACTS_DIR}/network.plan.tsv}"
NETWORK_VERIFY_PATH="${PROXMOX_NETWORK_VERIFY_PATH:-${FACTS_DIR}/network.verify.tsv}"

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

COLLECTED_AT=""
HOSTNAME_SHORT=""
PVE_VERSION=""
KERNEL_VERSION=""
DEFAULT_ROUTE_LINE=""
DEFAULT_GATEWAY=""
DEFAULT_ROUTE_DEV=""
DISCOVERED_ADMIN_BRIDGE=""
DISCOVERED_ADMIN_NIC=""
DISCOVERED_ADMIN_IP_CIDR=""
DISCOVERED_DATA_BRIDGE=""
DISCOVERED_DATA_NICS=""
OPEN_TTY=0
CURRENT_STAGE="startup"
PARTIAL_ERROR_PATH=""
TRACE_PATH=""
TRACE_FD_OPEN=0

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
  PROXMOX_NETWORK_EXPECTED_ADMIN_BRIDGE=vmbr0
  PROXMOX_NETWORK_EXPECTED_DATA_BRIDGE=vmbr1
  PROXMOX_NETWORK_EXPECTED_LAN_CIDR=10.0.0.0/24
  PROXMOX_NETWORK_EXPECTED_GUEST_ADMIN_IF=eth0
  PROXMOX_NETWORK_EXPECTED_GUEST_DATA_IF=eth1
  PROXMOX_NETWORK_CTIDS=100,101
  PROXMOX_NETWORK_VMIDS=200,201
  PROXMOX_NETWORK_UPDATE_MODE=check|apply
  PROXMOX_NETWORK_UPDATE_AUTO_APPLY=0|1
  PROXMOX_NETWORK_UPDATE_VLAN_TAG=<vid>   # defaults to 1 when unset
  PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS=10;20;30
  PROXMOX_NETWORK_UPDATE_VM_MODEL=virtio
  PROXMOX_NETWORK_UPDATE_LXCS=100,101
  PROXMOX_NETWORK_UPDATE_VMS=200,201
  PROXMOX_NETWORK_UPDATE_LXC_STRATEGY=highspeed_only|add_data_nic

Safety:
  Preflight/report remain read-only. Update mode changes guest NIC config
  through Ansible with an explicit check -> apply gate. Samba hardening is
  intentionally out of scope here and belongs in a separate script.
EOF
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is.true() {
  local value="${1:-}"
  case "${value,,}" in
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
  for cmd in awk bash bridge date grep hostname ip pct pvesh qm sed uname; do
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
  for cmd in awk bash grep ip pct qm sed sort wget; do
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
  write.partial.error "${line_no}" "${exit_code}"
  log.error "Preflight failed at stage=${CURRENT_STAGE} line=${line_no} exit=${exit_code}"
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
  if [[ "${exit_code}" -ne 0 && -n "${RUN_DIR}" && -n "${PARTIAL_ERROR_PATH}" && ! -f "${PARTIAL_ERROR_PATH}" ]]; then
    write.partial.error "exit" "${exit_code}"
  fi
}

trap 'on.err "${LINENO}" "$?"' ERR
trap 'on.exit "$?"' EXIT

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
  TRACE_PATH="${RUN_DIR}/network.trace.log"
}

update.latest.pointer() {
  mkdir -p "${OUTPUT_ROOT}"
  ln -sfn "${RUN_DIR}" "${OUTPUT_ROOT}/latest"
  printf '%s\n' "${RUN_DIR}" > "${OUTPUT_ROOT}/latest.path"
}

discover.basic.host.facts() {
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
  if [[ -n "${DEFAULT_ROUTE_DEV}" && -L "/sys/class/net/${DEFAULT_ROUTE_DEV}/master" ]]; then
    DISCOVERED_ADMIN_BRIDGE="$(readlink.basename.or.empty "/sys/class/net/${DEFAULT_ROUTE_DEV}/master")"
  fi
  if [[ "${DISCOVERED_ADMIN_BRIDGE}" == "${DEFAULT_ROUTE_DEV}" ]]; then
    DISCOVERED_ADMIN_NIC="${DEFAULT_ROUTE_DEV}"
  else
    DISCOVERED_ADMIN_NIC=""
  fi
  DISCOVERED_ADMIN_IP_CIDR="$(ip -o -4 addr show dev "${DISCOVERED_ADMIN_BRIDGE}" 2>/dev/null | awk '{print $4}' | paste -sd, -)"
  DISCOVERED_DATA_BRIDGE="${EXPECTED_DATA_BRIDGE}"
  log "Discovered admin bridge=${DISCOVERED_ADMIN_BRIDGE:-unknown} admin_nic=${DISCOVERED_ADMIN_NIC:-unknown} admin_ip=${DISCOVERED_ADMIN_IP_CIDR:-none} gateway=${DEFAULT_GATEWAY:-none}"
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
  local physical_data_nics=()
  local physical_admin_nics=()

  for iface_path in /sys/class/net/*; do
    [[ -d "${iface_path}" ]] || continue

    iface="$(basename "${iface_path}")"
    [[ -n "${iface}" ]] || continue
    if ! ip link show dev "${iface}" >/dev/null 2>&1; then
      log.warn "Skipping non-runtime network entry: ${iface}"
      continue
    fi

    if [[ "${iface}" == "lo" ]]; then
      kind="loopback"
    elif [[ -d "/sys/class/net/${iface}/bridge" ]]; then
      kind="bridge"
    elif [[ -e "/sys/class/net/${iface}/device" ]]; then
      kind="physical"
    else
      kind="virtual"
    fi

    mac="$(cat "/sys/class/net/${iface}/address" 2>/dev/null || true)"
    mtu="$(cat "/sys/class/net/${iface}/mtu" 2>/dev/null || true)"
    operstate="$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || true)"
    carrier="$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || true)"
    speed="$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || true)"
    duplex="$(cat "/sys/class/net/${iface}/duplex" 2>/dev/null || true)"
    driver="$(readlink.basename.or.empty "/sys/class/net/${iface}/device/driver")"
    pci_slot="$(readlink.basename.or.empty "/sys/class/net/${iface}/device")"
    master=""
    if [[ -L "/sys/class/net/${iface}/master" ]]; then
      master="$(readlink.basename.or.empty "/sys/class/net/${iface}/master")"
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
  DISCOVERED_DATA_NICS="$(join.by ',' "${physical_data_nics[@]}")"
  log "Collected NIC facts: $(awk 'END {print NR > 1 ? NR - 1 : 0}' "${NICS_TSV_PATH}") interfaces; data_nics=${DISCOVERED_DATA_NICS:-none}"
}

collect.bridges.tsv() {
  set.stage "collect.bridges.tsv"
  printf 'bridge\tvlan_filtering\tmembers\tipv4\tipv6\n' > "${BRIDGES_TSV_PATH}"

  local iface=""
  local vlan_filtering=""
  local members=""
  local ipv4=""
  local ipv6=""

  for iface in /sys/class/net/*; do
    iface="$(basename "${iface}")"
    [[ -d "/sys/class/net/${iface}/bridge" ]] || continue

    vlan_filtering="$(cat "/sys/class/net/${iface}/bridge/vlan_filtering" 2>/dev/null || true)"
    members="$(bridge link show master "${iface}" 2>/dev/null | sed -n 's/^[0-9]\+: \([^:@[:space:]]*\).*/\1/p' | paste -sd, -)"
    ipv4="$(ip -o -4 addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | paste -sd, -)"
    ipv6="$(ip -o -6 addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | paste -sd, -)"

    append.tsv.row "${BRIDGES_TSV_PATH}" "${iface}" "${vlan_filtering}" "${members}" "${ipv4}" "${ipv6}"
  done
  log "Collected bridge facts: $(awk 'END {print NR > 1 ? NR - 1 : 0}' "${BRIDGES_TSV_PATH}") bridge rows"
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
      capture.cmd "${runtime_dir}/ip.o4.addr.txt" "pct exec ${id} -- ip -o -4 addr show" "pct exec ${id} -- ip -o -4 addr show"
      capture.cmd "${runtime_dir}/ip.route.txt" "pct exec ${id} -- ip route" "pct exec ${id} -- ip route"
      capture.cmd "${runtime_dir}/ss.ltnp.txt" "pct exec ${id} -- ss -ltnp" "pct exec ${id} -- ss -ltnp"
      capture.cmd "${runtime_dir}/interfaces.txt" "pct exec ${id} -- cat /etc/network/interfaces" "pct exec ${id} -- cat /etc/network/interfaces"
      capture.cmd "${runtime_dir}/interfaces.d.list.txt" "pct exec ${id} -- ls -1 /etc/network/interfaces.d" "pct exec ${id} -- bash -lc 'ls -1 /etc/network/interfaces.d 2>/dev/null || true'"
      capture.cmd "${runtime_dir}/sysctl.arp-rpf.txt" "pct exec ${id} -- sysctl ARP/rp_filter" \
        "pct exec ${id} -- bash -lc 'sysctl net.ipv4.conf.all.arp_ignore net.ipv4.conf.all.arp_announce net.ipv4.conf.all.rp_filter net.ipv4.conf.${EXPECTED_GUEST_ADMIN_IF}.rp_filter net.ipv4.conf.${EXPECTED_GUEST_DATA_IF}.rp_filter 2>/dev/null || true'"
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

      if [[ -n "${runtime_default_route}" && "${runtime_default_route}" == *"dev ${EXPECTED_GUEST_DATA_IF}"* ]]; then
        append.risk "warn" "lxc" "${id}" "${name}" "data_nic_default_route" \
          "Default route currently points at ${EXPECTED_GUEST_DATA_IF}; admin traffic may not stay on ${EXPECTED_GUEST_ADMIN_IF}."
      fi
      if [[ "${service_present}" == "yes" && "${testparm_interfaces}" == *"${EXPECTED_GUEST_ADMIN_IF}"* ]]; then
        append.risk "warn" "samba" "${id}" "${name}" "samba_bound_to_admin_if" \
          "Samba interfaces include ${EXPECTED_GUEST_ADMIN_IF}; file traffic may leak onto the admin path."
      fi
      if [[ "${service_present}" == "yes" && -n "${data_nic_name}" && "${testparm_interfaces}" != *"${data_nic_name}"* ]]; then
        append.risk "warn" "samba" "${id}" "${name}" "samba_missing_data_if" \
          "Samba interfaces do not include the container data NIC ${data_nic_name}."
      fi
      if [[ "${testparm_hosts_allow}" == *"192.168.0.0/16"* ]]; then
        append.risk "warn" "samba" "${id}" "${name}" "legacy_broad_hosts_allow" \
          "Samba hosts allow still includes 192.168.0.0/16."
      fi
      if [[ "${service_present}" == "yes" && "${testparm_hosts_allow}" != *"${EXPECTED_LAN_CIDR}"* ]]; then
        append.risk "warn" "samba" "${id}" "${name}" "expected_lan_missing_from_hosts_allow" \
          "Samba hosts allow does not clearly include ${EXPECTED_LAN_CIDR}."
      fi
    else
      append.tsv.row "${GUEST_RUNTIME_TSV_PATH}" \
        "lxc" "${id}" "${name}" "${status}" "unavailable" "-" "-" "-" "-"
      append.tsv.row "${SAMBA_TSV_PATH}" \
        "lxc" "${id}" "${name}" "${status}" "unknown" "-" "-" "-" "-" "-"
    fi
  done
  log "Collected LXC facts: $(awk 'END {print NR > 1 ? NR - 1 : 0}' "${LXC_TSV_PATH}") NIC rows"
}

collect.vm.data() {
  set.stage "collect.vm.data"
  printf 'guest_type\tguest_id\tguest_name\tstatus\tnet_slot\tmodel\tmac\tbridge\tvlan_tag\ttrunks\tfirewall\tmtu\traw\n' > "${VM_TSV_PATH}"

  local id=""
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
  log "Collected VM facts: $(awk 'END {print NR > 1 ? NR - 1 : 0}' "${VM_TSV_PATH}") NIC rows"
}

classify.host.risks() {
  set.stage "classify.host.risks"
  printf 'severity\tscope\tguest_id\tguest_name\tcode\tdetail\n' > "${RISKS_TSV_PATH}"

  local data_bridge_row=""
  local data_members=""
  local data_ipv4=""
  local data_vlan_filtering=""

  data_bridge_row="$(awk -F'\t' -v bridge="${EXPECTED_DATA_BRIDGE}" '$1 == bridge {print $0; exit}' "${BRIDGES_TSV_PATH}" 2>/dev/null || true)"
  if [[ -z "${data_bridge_row}" ]]; then
    append.risk "error" "host" "-" "${HOSTNAME_SHORT}" "missing_data_bridge" \
      "Expected data bridge ${EXPECTED_DATA_BRIDGE} was not found."
  else
    data_vlan_filtering="$(awk -F'\t' -v bridge="${EXPECTED_DATA_BRIDGE}" '$1 == bridge {print $2; exit}' "${BRIDGES_TSV_PATH}" 2>/dev/null || true)"
    data_members="$(awk -F'\t' -v bridge="${EXPECTED_DATA_BRIDGE}" '$1 == bridge {print $3; exit}' "${BRIDGES_TSV_PATH}" 2>/dev/null || true)"
    data_ipv4="$(awk -F'\t' -v bridge="${EXPECTED_DATA_BRIDGE}" '$1 == bridge {print $4; exit}' "${BRIDGES_TSV_PATH}" 2>/dev/null || true)"

    if [[ "${data_vlan_filtering}" != "1" ]]; then
      append.risk "warn" "host" "-" "${HOSTNAME_SHORT}" "data_bridge_not_vlan_aware" \
        "Bridge ${EXPECTED_DATA_BRIDGE} does not report vlan_filtering=1."
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
  log "Classified risks: $(awk 'END {print NR > 1 ? NR - 1 : 0}' "${RISKS_TSV_PATH}") findings"
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
    lan_cidr: $(yaml.quote "${EXPECTED_LAN_CIDR}")
    guest_admin_if: $(yaml.quote "${EXPECTED_GUEST_ADMIN_IF}")
    guest_data_if: $(yaml.quote "${EXPECTED_GUEST_DATA_IF}")
  discovered:
    pve_version: $(yaml.quote "${PVE_VERSION}")
    kernel_version: $(yaml.quote "${KERNEL_VERSION}")
    default_route: $(yaml.quote "${DEFAULT_ROUTE_LINE}")
    default_gateway: $(yaml.quote "${DEFAULT_GATEWAY}")
    admin_bridge: $(yaml.quote "${DISCOVERED_ADMIN_BRIDGE}")
    admin_nic: $(yaml.quote "${DISCOVERED_ADMIN_NIC}")
    admin_ip_cidr: $(yaml.quote "${DISCOVERED_ADMIN_IP_CIDR}")
    data_bridge: $(yaml.quote "${DISCOVERED_DATA_BRIDGE}")
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
EOF
}

write.next.stage.env() {
  set.stage "write.next.stage.env"
  cat > "${ENV_PATH}" <<EOF
# Saved by setup/network.sh preflight
export PROXMOX_NETWORK_REPORT_DIR=$(yaml.quote "${RUN_DIR}")
export PROXMOX_NETWORK_EXPECTED_ADMIN_BRIDGE=$(yaml.quote "${EXPECTED_ADMIN_BRIDGE}")
export PROXMOX_NETWORK_EXPECTED_DATA_BRIDGE=$(yaml.quote "${EXPECTED_DATA_BRIDGE}")
export PROXMOX_NETWORK_EXPECTED_LAN_CIDR=$(yaml.quote "${EXPECTED_LAN_CIDR}")
export PROXMOX_NETWORK_EXPECTED_GUEST_ADMIN_IF=$(yaml.quote "${EXPECTED_GUEST_ADMIN_IF}")
export PROXMOX_NETWORK_EXPECTED_GUEST_DATA_IF=$(yaml.quote "${EXPECTED_GUEST_DATA_IF}")
export PROXMOX_NETWORK_DISCOVERED_ADMIN_BRIDGE=$(yaml.quote "${DISCOVERED_ADMIN_BRIDGE}")
export PROXMOX_NETWORK_DISCOVERED_ADMIN_NIC=$(yaml.quote "${DISCOVERED_ADMIN_NIC}")
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
    lan_cidr: $(yaml.quote "${EXPECTED_LAN_CIDR}")
    guest_admin_if: $(yaml.quote "${EXPECTED_GUEST_ADMIN_IF}")
    guest_data_if: $(yaml.quote "${EXPECTED_GUEST_DATA_IF}")
  discovered:
    admin_bridge: $(yaml.quote "${DISCOVERED_ADMIN_BRIDGE}")
    admin_nic: $(yaml.quote "${DISCOVERED_ADMIN_NIC}")
    admin_ip_cidr: $(yaml.quote "${DISCOVERED_ADMIN_IP_CIDR}")
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
EOF

  cp -f "${LXC_TSV_PATH}" "${FACTS_DIR}/network.lxc.latest.tsv"
  cp -f "${VM_TSV_PATH}" "${FACTS_DIR}/network.vm.latest.tsv"
  cp -f "${NICS_TSV_PATH}" "${FACTS_DIR}/network.nics.latest.tsv"
  cp -f "${BRIDGES_TSV_PATH}" "${FACTS_DIR}/network.bridges.latest.tsv"
  cp -f "${RISKS_TSV_PATH}" "${FACTS_DIR}/network.risks.latest.tsv"
  cp -f "${SUMMARY_PATH}" "${FACTS_DIR}/network.summary.latest.txt"

  cat > "${ANSIBLE_PREFLIGHT_FACTS_JSON}" <<EOF
{"proxmox_network_preflight_latest":{"generated_by":"setup/network.sh","generated_at":"${COLLECTED_AT}","hostname":"${HOSTNAME_SHORT}","run_dir":"${RUN_DIR}","expected":{"admin_bridge":"${EXPECTED_ADMIN_BRIDGE}","data_bridge":"${EXPECTED_DATA_BRIDGE}","lan_cidr":"${EXPECTED_LAN_CIDR}","guest_admin_if":"${EXPECTED_GUEST_ADMIN_IF}","guest_data_if":"${EXPECTED_GUEST_DATA_IF}"},"discovered":{"admin_bridge":"${DISCOVERED_ADMIN_BRIDGE}","admin_nic":"${DISCOVERED_ADMIN_NIC}","admin_ip_cidr":"${DISCOVERED_ADMIN_IP_CIDR}","data_nics":"${DISCOVERED_DATA_NICS}","default_gateway":"${DEFAULT_GATEWAY}"}}}
EOF
  log "Exported preflight facts for Ansible: ${ANSIBLE_PREFLIGHT_FACTS_YAML}"
}

write.summary() {
  set.stage "write.summary"
  local ct_count vm_count nic_count bridge_count risk_total risk_error risk_warn risk_info
  ct_count="$(awk 'END {print NR > 1 ? NR - 1 : 0}' "${LXC_TSV_PATH}" 2>/dev/null || printf '0')"
  vm_count="$(awk 'END {print NR > 1 ? NR - 1 : 0}' "${VM_TSV_PATH}" 2>/dev/null || printf '0')"
  nic_count="$(awk 'END {print NR > 1 ? NR - 1 : 0}' "${NICS_TSV_PATH}" 2>/dev/null || printf '0')"
  bridge_count="$(awk 'END {print NR > 1 ? NR - 1 : 0}' "${BRIDGES_TSV_PATH}" 2>/dev/null || printf '0')"
  risk_total="$(awk 'END {print NR > 1 ? NR - 1 : 0}' "${RISKS_TSV_PATH}" 2>/dev/null || printf '0')"
  risk_error="$(awk -F'\t' '$1 == "error" {count++} END {print count + 0}' "${RISKS_TSV_PATH}" 2>/dev/null || printf '0')"
  risk_warn="$(awk -F'\t' '$1 == "warn" {count++} END {print count + 0}' "${RISKS_TSV_PATH}" 2>/dev/null || printf '0')"
  risk_info="$(awk -F'\t' '$1 == "info" {count++} END {print count + 0}' "${RISKS_TSV_PATH}" 2>/dev/null || printf '0')"

  {
    printf 'Proxmox Network Preflight Summary\n'
    printf 'Host: %s\n' "${HOSTNAME_SHORT}"
    printf 'Collected: %s\n' "${COLLECTED_AT}"
    printf 'Run Directory: %s\n' "${RUN_DIR}"
    printf 'Next-Stage Env: %s\n' "${ENV_PATH}"
    printf '\n'
    printf 'Expected Admin Bridge: %s\n' "${EXPECTED_ADMIN_BRIDGE}"
    printf 'Expected Data Bridge: %s\n' "${EXPECTED_DATA_BRIDGE}"
    printf 'Expected LAN CIDR: %s\n' "${EXPECTED_LAN_CIDR}"
    printf '\n'
    printf 'Discovered Admin Bridge: %s\n' "${DISCOVERED_ADMIN_BRIDGE}"
    printf 'Discovered Admin NIC: %s\n' "${DISCOVERED_ADMIN_NIC}"
    printf 'Discovered Admin IP/CIDR: %s\n' "${DISCOVERED_ADMIN_IP_CIDR}"
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
    printf '  - %s\n' "${ANSIBLE_PREFLIGHT_FACTS_YAML}"
    printf '  - %s\n' "${ANSIBLE_PREFLIGHT_FACTS_JSON}"
    printf '\n'
    printf 'Suggested Next Step:\n'
    printf '  source %s\n' "${ENV_PATH}"
  } > "${SUMMARY_PATH}"
}

print.discovery.preview() {
  printf '\n'
  printf 'Discovered host defaults:\n' >&3
  printf '  host: %s\n' "${HOSTNAME_SHORT}" >&3
  printf '  output root: %s\n' "${OUTPUT_ROOT}" >&3
  printf '  admin bridge: %s\n' "${DISCOVERED_ADMIN_BRIDGE:-${EXPECTED_ADMIN_BRIDGE}}" >&3
  printf '  admin nic: %s\n' "${DISCOVERED_ADMIN_NIC:-unknown}" >&3
  printf '  admin ip: %s\n' "${DISCOVERED_ADMIN_IP_CIDR:-none}" >&3
  printf '  default gateway: %s\n' "${DEFAULT_GATEWAY:-none}" >&3
  printf '  data bridge: %s\n' "${EXPECTED_DATA_BRIDGE}" >&3
  printf '  guest admin if: %s\n' "${EXPECTED_GUEST_ADMIN_IF}" >&3
  printf '  guest data if: %s\n' "${EXPECTED_GUEST_DATA_IF}" >&3
  printf '  expected LAN CIDR: %s\n' "${EXPECTED_LAN_CIDR}" >&3
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
      EXPECTED_LAN_CIDR="$(prompt.tty "Enter expected LAN CIDR" "${EXPECTED_LAN_CIDR}")"
      EXPECTED_GUEST_ADMIN_IF="$(prompt.tty "Enter guest admin interface name" "${EXPECTED_GUEST_ADMIN_IF}")"
      EXPECTED_GUEST_DATA_IF="$(prompt.tty "Enter guest data interface name" "${EXPECTED_GUEST_DATA_IF}")"
      CTID_FILTER="$(trim.space "$(prompt.tty "Enter LXC IDs to inspect (blank = all discovered)" "${CTID_FILTER}")")"
      VMID_FILTER="$(trim.space "$(prompt.tty "Enter VM IDs to inspect (blank = all discovered)" "${VMID_FILTER}")")"
      printf '\nFinal preflight selection:\n' >&3
      printf '  output root: %s\n' "${OUTPUT_ROOT}" >&3
      printf '  expected admin bridge: %s\n' "${EXPECTED_ADMIN_BRIDGE}" >&3
      printf '  expected data bridge: %s\n' "${EXPECTED_DATA_BRIDGE}" >&3
      printf '  expected LAN CIDR: %s\n' "${EXPECTED_LAN_CIDR}" >&3
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
  elif [[ -L "${OUTPUT_ROOT}/latest" ]]; then
    resolved="$(readlink "${OUTPUT_ROOT}/latest")"
    if [[ "${resolved}" != /* ]]; then
      resolved="${OUTPUT_ROOT}/${resolved}"
    fi
  elif [[ -f "${OUTPUT_ROOT}/latest.path" ]]; then
    resolved="$(cat "${OUTPUT_ROOT}/latest.path")"
  fi

  if [[ -z "${resolved}" || ! -d "${resolved}" ]]; then
    log.error "No saved preflight snapshot directory found for update mode."
    log.error "Run ./setup/network.sh preflight first, or set PROXMOX_NETWORK_SNAPSHOT_DIR."
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
  fi
}

require.snapshot.artifacts() {
  local missing=0
  local path=""
  for path in \
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
}

use.local.feature.files() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"

  if [[ -r "${repo_root}/ansible/${NETWORK_EXPORT_PLAYBOOK_REL}" \
    && -r "${repo_root}/ansible/${NETWORK_UPDATE_PLAYBOOK_REL}" \
    && -r "${repo_root}/ansible/${NETWORK_VERIFY_PLAYBOOK_REL}" \
    && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]]; then
    PLAYBOOK_ROOT="${repo_root}/ansible"
    PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
    GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
    NETWORK_EXPORT_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_EXPORT_PLAYBOOK_REL}"
    NETWORK_UPDATE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_UPDATE_PLAYBOOK_REL}"
    NETWORK_VERIFY_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_VERIFY_PLAYBOOK_REL}"
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

lxc.net.body.by.slot() {
  local config_path="${1:-}"
  local slot="${2:-}"
  [[ -f "${config_path}" ]] || return 1
  sed -n "s/^${slot}: //p" "${config_path}" 2>/dev/null | head -n1
}

build.lxc.highspeed.only.body() {
  local current_body="${1:-}"
  local desired=""
  desired="${current_body}"
  desired="$(upsert.csv.kv "${desired}" "bridge" "${EXPECTED_DATA_BRIDGE}")"
  if [[ -n "${PROXMOX_NETWORK_UPDATE_VLAN_TAG}" ]]; then
    desired="$(drop.csv.kv "${desired}" "trunks")"
    desired="$(upsert.csv.kv "${desired}" "tag" "${PROXMOX_NETWORK_UPDATE_VLAN_TAG}")"
  elif [[ -n "${PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS}" ]]; then
    desired="$(drop.csv.kv "${desired}" "tag")"
    desired="$(upsert.csv.kv "${desired}" "trunks" "${PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS}")"
  else
    desired="$(drop.csv.kv "${desired}" "tag")"
    desired="$(drop.csv.kv "${desired}" "trunks")"
  fi
  printf '%s' "${desired}"
}

vm.has.any.nic() {
  local id="$1"
  awk -F'\t' -v target="${id}" 'NR > 1 && $2 == target {found=1} END {exit(found ? 0 : 1)}' "${VM_TSV_PATH}" 2>/dev/null
}

candidate.lxc.ids() {
  awk -F'\t' -v admin="${EXPECTED_ADMIN_BRIDGE}" -v data="${EXPECTED_DATA_BRIDGE}" '
    NR > 1 {
      id = $2
      name[id] = $3
      if ($7 == admin) has_admin[id] = 1
      if ($7 == data) has_data[id] = 1
    }
    END {
      for (id in name) {
        if (has_admin[id] && !has_data[id]) {
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

collect.update.selection() {
  local candidate_lxc_csv candidate_vm_csv choice manual_lxc manual_vm selected_lxc
  candidate_lxc_csv="$(csv.from.id.list UPDATE_LXC_IDS)"
  candidate_vm_csv="$(csv.from.id.list UPDATE_VM_IDS)"

  if [[ -n "${PROXMOX_NETWORK_UPDATE_VLAN_TAG}" ]]; then
    PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS=""
  fi

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
    if [[ -n "${PROXMOX_NETWORK_UPDATE_VMS}" ]]; then
      UPDATE_VM_IDS=()
      while IFS= read -r choice; do
        append.unique.id UPDATE_VM_IDS "${choice}"
      done < <(parse.id.filter "${PROXMOX_NETWORK_UPDATE_VMS}")
    elif [[ -n "${VMID_FILTER}" ]]; then
      UPDATE_VM_IDS=()
      while IFS= read -r choice; do
        append.unique.id UPDATE_VM_IDS "${choice}"
      done < <(parse.id.filter "${VMID_FILTER}")
    fi
    return 0
  fi

  printf '\nNetwork update candidate summary:\n' >&3
  printf '  Snapshot: %s\n' "${RUN_DIR}" >&3
  printf '  Candidate LXC IDs missing data NIC: %s\n' "${candidate_lxc_csv:-none}" >&3
  printf '  Candidate VM IDs missing data NIC: %s\n' "${candidate_vm_csv:-none}" >&3
  printf '  Default data bridge: %s\n' "${EXPECTED_DATA_BRIDGE}" >&3
  printf '\n' >&3

  choice="$(menu.tty "Select update scope:" "selected LXC fix" "all candidates" "manual IDs" "abort")"
  case "${choice}" in
    1)
      selected_lxc="$(prompt.tty "Enter LXC ID to fix" "${candidate_lxc_csv%%,*}")"
      UPDATE_LXC_IDS=()
      UPDATE_VM_IDS=()
      while IFS= read -r choice; do
        append.unique.id UPDATE_LXC_IDS "${choice}"
      done < <(parse.id.filter "${selected_lxc}")
      ;;
    2)
      ;;
    3)
      manual_lxc="$(prompt.tty "Enter LXC IDs to update (blank = none)" "${candidate_lxc_csv}")"
      manual_vm="$(prompt.tty "Enter VM IDs to update (blank = none)" "${candidate_vm_csv}")"
      UPDATE_LXC_IDS=()
      UPDATE_VM_IDS=()
      while IFS= read -r choice; do
        append.unique.id UPDATE_LXC_IDS "${choice}"
      done < <(parse.id.filter "${manual_lxc}")
      while IFS= read -r choice; do
        append.unique.id UPDATE_VM_IDS "${choice}"
      done < <(parse.id.filter "${manual_vm}")
      ;;
    *)
      log.error "Aborted by operator."
      exit 1
      ;;
  esac

  EXPECTED_DATA_BRIDGE="$(prompt.tty "Enter target high-speed bridge" "${EXPECTED_DATA_BRIDGE}")"
  if ((${#UPDATE_LXC_IDS[@]} > 0)); then
    choice="$(menu.tty "Select LXC network strategy:" "high-speed only on VLAN 1 (replace net0)" "keep admin NIC and add data NIC")"
    case "${choice}" in
      1) PROXMOX_NETWORK_UPDATE_LXC_STRATEGY="highspeed_only" ;;
      2) PROXMOX_NETWORK_UPDATE_LXC_STRATEGY="add_data_nic" ;;
      *) log.error "Invalid LXC strategy selection."; exit 1 ;;
    esac
  fi

  PROXMOX_NETWORK_UPDATE_VLAN_TAG="$(trim.space "$(prompt.tty "Enter VLAN tag (blank = none, default = 1)" "${PROXMOX_NETWORK_UPDATE_VLAN_TAG}")")"
  if [[ -z "${PROXMOX_NETWORK_UPDATE_VLAN_TAG}" ]]; then
    PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS="$(trim.space "$(prompt.tty "Enter VLAN trunks (blank = none)" "${PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS}")")"
  else
    PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS=""
  fi
  PROXMOX_NETWORK_UPDATE_VM_MODEL="$(trim.space "$(prompt.tty "Enter VM NIC model" "${PROXMOX_NETWORK_UPDATE_VM_MODEL}")")"
  if [[ -z "${PROXMOX_NETWORK_UPDATE_VM_MODEL}" ]]; then
    PROXMOX_NETWORK_UPDATE_VM_MODEL="virtio"
  fi

  if [[ "${PROXMOX_NETWORK_UPDATE_MODE}" == "apply" ]]; then
    choice="$(menu.tty "Run apply stage after check preview?" "yes" "no")"
    if [[ "${choice}" == "2" ]]; then
      PROXMOX_NETWORK_UPDATE_MODE="check"
    fi
  else
    choice="$(menu.tty "Update mode:" "check only" "check then apply")"
    if [[ "${choice}" == "2" ]]; then
      PROXMOX_NETWORK_UPDATE_MODE="apply"
    fi
  fi
}

build.network.update.plan() {
  local id name conf_path slot desired current_body
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

    if [[ "${PROXMOX_NETWORK_UPDATE_LXC_STRATEGY}" == "highspeed_only" ]]; then
      current_body="$(lxc.net.body.by.slot "${conf_path}" "net0" || true)"
      if [[ -z "${current_body}" ]]; then
        log.warn "Skipping LXC ${id}: high-speed-only mode requires existing net0."
        continue
      fi
      if lxc.has.data.nic "${id}" && ! lxc.has.admin.nic "${id}"; then
        log "Skipping LXC ${id}: it already appears to be data-only."
        continue
      fi
      slot="net0"
      desired="$(build.lxc.highspeed.only.body "${current_body}")"
      append.tsv.row "${NETWORK_PLAN_PATH}" "lxc" "${id}" "${name}" "${slot}" "${desired}" "selected_lxc_highspeed_only"
      row_count=$((row_count + 1))
      continue
    fi

    if ! lxc.has.admin.nic "${id}"; then
      log.warn "Skipping LXC ${id}: no admin NIC on ${EXPECTED_ADMIN_BRIDGE}."
      continue
    fi
    if lxc.has.data.nic "${id}"; then
      log "Skipping LXC ${id}: already has a data NIC on ${EXPECTED_DATA_BRIDGE}."
      continue
    fi
    slot="$(pick.free.net.slot "${conf_path}")"
    if [[ -z "${slot}" ]]; then
      log.warn "Skipping LXC ${id}: no free net slot from net1..net9."
      continue
    fi
    desired="name=${EXPECTED_GUEST_DATA_IF},bridge=${EXPECTED_DATA_BRIDGE},ip=dhcp"
    if [[ -n "${PROXMOX_NETWORK_UPDATE_VLAN_TAG}" ]]; then
      desired="${desired},tag=${PROXMOX_NETWORK_UPDATE_VLAN_TAG}"
    elif [[ -n "${PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS}" ]]; then
      desired="${desired},trunks=${PROXMOX_NETWORK_UPDATE_VLAN_TRUNKS}"
    fi
    append.tsv.row "${NETWORK_PLAN_PATH}" "lxc" "${id}" "${name}" "${slot}" "${desired}" "missing_data_nic_add_data_nic"
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
    lan_cidr: $(yaml.quote "${EXPECTED_LAN_CIDR}")
    guest_admin_if: $(yaml.quote "${EXPECTED_GUEST_ADMIN_IF}")
    guest_data_if: $(yaml.quote "${EXPECTED_GUEST_DATA_IF}")
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
proxmox_network_update_mode: $(yaml.quote "${mode}")
proxmox_network_expected_admin_bridge: $(yaml.quote "${EXPECTED_ADMIN_BRIDGE}")
proxmox_network_expected_data_bridge: $(yaml.quote "${EXPECTED_DATA_BRIDGE}")
proxmox_network_expected_lan_cidr: $(yaml.quote "${EXPECTED_LAN_CIDR}")
proxmox_network_update_apply_requested: ${apply_requested}
EOF
}

run.network.update.flow() {
  local apply_requested=0 choice prev_interactive

  resolve.snapshot.dir
  load.snapshot.defaults
  require.snapshot.artifacts
  load.update.candidates
  collect.update.selection
  build.network.update.plan
  if ! awk 'NR > 1 {found=1} END {exit(found ? 0 : 1)}' "${NETWORK_PLAN_PATH}" 2>/dev/null; then
    log.warn "No actionable plan rows found. Update stage exiting without changes."
    return 0
  fi

  write.network.intent.file
  log "Network update scope is limited to guest NIC config. Samba hardening stays in a separate script."

  ensure.network.ansible
  prepare.feature.files

  write.network.extra.vars.file "check"
  run.feature.playbook "${NETWORK_EXPORT_PLAYBOOK_PATH}" -e "@${NETWORK_EXTRA_VARS_PATH}"
  run.feature.playbook "${NETWORK_UPDATE_PLAYBOOK_PATH}" -e "@${NETWORK_EXTRA_VARS_PATH}"

  if [[ "${PROXMOX_NETWORK_UPDATE_MODE}" == "apply" ]] || is.true "${PROXMOX_NETWORK_UPDATE_AUTO_APPLY}"; then
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

  write.network.extra.vars.file "apply"
  run.feature.playbook "${NETWORK_UPDATE_PLAYBOOK_PATH}" -e "@${NETWORK_EXTRA_VARS_PATH}"
  run.feature.playbook "${NETWORK_VERIFY_PLAYBOOK_PATH}" -e "@${NETWORK_EXTRA_VARS_PATH}"

  log "Apply phase complete. Running post-apply preflight snapshot."
  prev_interactive="${FEATURE_INTERACTIVE}"
  FEATURE_INTERACTIVE=0
  run.preflight
  FEATURE_INTERACTIVE="${prev_interactive}"
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
  write.host.yaml
  write.next.stage.env
  write.summary
  export.preflight.facts.for.ansible
  update.latest.pointer

  log "Preflight complete. Saved network snapshot to ${RUN_DIR}"
  cat "${SUMMARY_PATH}"
}

resolve.report.dir() {
  local resolved=""
  if [[ -n "${REPORT_DIR_OVERRIDE}" ]]; then
    resolved="${REPORT_DIR_OVERRIDE}"
  elif [[ -L "${OUTPUT_ROOT}/latest" ]]; then
    resolved="$(readlink "${OUTPUT_ROOT}/latest")"
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

main "$@"
