#!/usr/bin/env bash
## Proxmox LXC network access feature runner.
## Local usage:
##   ./setup/lxc/network.sh [preflight|apply]
## Published usage:
##   wget -qO- https://devs-guide.github.io/proxmox/setup/lxc/network.sh | bash

set -euo pipefail

log()       { printf '[setup.lxc.network] %s\n' "$*" >&2; }
log.error() { printf '[setup.lxc.network][error] %s\n' "$*" >&2; }
log.warn()  { printf '[setup.lxc.network][warn] %s\n' "$*" >&2; }

TMP_DIR="/tmp/pve-feature-lxc-network"
PAGES_BASE_URL="https://devs-guide.github.io/proxmox"
PLAYBOOK_ROOT="${TMP_DIR}/ansible"
PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
LOCAL_COMMON_HELPER="../../bootstrap/release.common.sh"
COMMON_HELPER_NAME="release.common.sh"
COMMON_HELPER_URL="${PAGES_BASE_URL}/${COMMON_HELPER_NAME}"
COMMON_HELPER_PATH="${TMP_DIR}/${COMMON_HELPER_NAME}"
GROUP_VARS_FILE="proxmox.yml"
GROUP_VARS_URL="${PAGES_BASE_URL}/ansible/group_vars/${GROUP_VARS_FILE}"
GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"

FEATURE_PLAYBOOKS=(
  "proxmox/container/network.access.yml"
)
NETWORK_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[0]}"
NETWORK_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${NETWORK_PLAYBOOK_REL}"
NETWORK_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_PLAYBOOK_REL}"
NETWORK_EXTRA_VARS_PATH="${TMP_DIR}/network.extra-vars.yml"

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
MANAGED_TARGET_HANDOFF_MARKER="${PROXMOX_BOOTSTRAP_MANAGED_TARGET_HOH:-${MANAGED_TARGET_PYTHON_HOME}/.handoff-ready}"
PYTHON_BOOTSTRAP_BIN=""

FACTS_DIR="${PROXMOX_LXC_NETWORK_FACTS_DIR:-/etc/ansible/proxmox/facts}"
NETWORK_CONTAINER_FACTS_PATH="${PROXMOX_LXC_NETWORK_CONTAINER_FACTS_PATH:-${FACTS_DIR}/container.yml}"
NETWORK_RUNTIME_FACTS_PATH="${PROXMOX_LXC_NETWORK_RUNTIME_FACTS_PATH:-${FACTS_DIR}/lxc.network.yml}"
NETWORK_SELECTION_PATH="${PROXMOX_LXC_NETWORK_SELECTION_PATH:-${FACTS_DIR}/lxc.network.selection.yml}"

FEATURE_MODE="${1:-${PROXMOX_LXC_NETWORK_MODE:-preflight}}"
FEATURE_INTERACTIVE="${PROXMOX_LXC_NETWORK_INTERACTIVE:-1}"
FEATURE_ALLOW_HOST="${PROXMOX_LXC_NETWORK_ALLOW_HOST:-0}"
FEATURE_ASSUME_CONTAINER="${PROXMOX_LXC_NETWORK_ASSUME_CONTAINER:-0}"
FEATURE_REQUIRE_CONTAINER="${PROXMOX_LXC_NETWORK_REQUIRE_CONTAINER:-1}"
FEATURE_ENABLE_SSH="${PROXMOX_LXC_NETWORK_ENABLE_SSH:-1}"
FEATURE_ENABLE_UFW="${PROXMOX_LXC_NETWORK_ENABLE_UFW:-1}"
FEATURE_ENABLE_FUSE_CLIENT="${PROXMOX_LXC_NETWORK_ENABLE_FUSE_CLIENT:-0}"
FEATURE_ENABLE_AVAHI="${PROXMOX_LXC_NETWORK_ENABLE_AVAHI:-0}"
FEATURE_EXPECTED_DNS="${PROXMOX_LXC_NETWORK_EXPECTED_DNS:-10.0.0.1}"
FEATURE_INTERNET_PROBE_IPV4="${PROXMOX_LXC_NETWORK_INTERNET_PROBE_IPV4:-1.1.1.1}"
FEATURE_ACCESS_PROFILE="${PROXMOX_LXC_NETWORK_ACCESS_PROFILE:-local_only}"
FEATURE_ALLOW_SUBNETS="${PROXMOX_LXC_NETWORK_ALLOW_SUBNETS:-10.0.0.0/24 192.168.0.0/16}"
FEATURE_ACCESS_USERS="${PROXMOX_LXC_NETWORK_ACCESS_USERS:-agent proxmox root}"
FEATURE_SSH_PORT="${PROXMOX_LXC_NETWORK_SSH_PORT:-22}"

CONTAINER_HOSTNAME=""
CONTAINER_CTID="${PROXMOX_CTID:-}"
CONTAINER_CTNAME="${PROXMOX_CTNAME:-}"
CONTAINER_OS_PRETTY=""
CONTAINER_DEFAULT_ROUTE=""
OPEN_TTY=0

declare -a NETWORK_ALLOW_SUBNET_LIST=()
declare -a NETWORK_ACCESS_USERS=()
declare -a CONTAINER_IPV4=()

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
  # shellcheck source=/tmp/pve-feature-lxc-network/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

source.release.common

is.true() {
  case "${1,,}" in
    1|true|yes|y|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
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
    printf "null"
  else
    yaml.quote "${value}"
  fi
}

bool.yaml() {
  if is.true "${1:-false}"; then
    printf "true"
  else
    printf "false"
  fi
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
    printf "%s [%s]: " "${prompt}" "${default}" >&3
  else
    printf "%s: " "${prompt}" >&3
  fi
  read -r -u 3 answer || true
  if [[ -z "${answer}" ]]; then
    answer="${default}"
  fi
  printf "%s\n" "${answer}"
}

menu.tty() {
  local prompt="$1"
  shift
  local -a options=("$@")
  local answer=""
  local i
  while true; do
    printf "%s\n" "${prompt}" >&3
    for i in "${!options[@]}"; do
      printf "  %d) %s\n" "$((i + 1))" "${options[$i]}" >&3
    done
    printf "Select option: " >&3
    read -r -u 3 answer || true
    if [[ "${answer}" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#options[@]})); then
      printf "%s\n" "${answer}"
      return 0
    fi
    printf "Invalid selection.\n" >&3
  done
}

require.valid.mode() {
  case "${FEATURE_MODE}" in
    preflight|apply)
      ;;
    -h|--help|help)
      cat <<EOF
Usage:
  ./setup/lxc/network.sh [preflight|apply]
EOF
      exit 0
      ;;
    *)
      log.error "Unsupported mode: ${FEATURE_MODE}"
      log.error "Use one of: preflight, apply"
      exit 1
      ;;
  esac
}

require.debian.container() {
  [[ -r /etc/os-release ]] || {
    log.error "Missing /etc/os-release; cannot confirm container OS."
    exit 1
  }
  # shellcheck disable=SC1091
  source /etc/os-release
  CONTAINER_OS_PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"
  if [[ "${ID:-}" != "debian" ]] && [[ "${ID_LIKE:-}" != *debian* ]]; then
    log.error "This feature expects a Debian-family LXC container."
    exit 1
  fi
}

require.container.not.host() {
  local detected_container=0
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    if systemd-detect-virt --quiet --container; then
      detected_container=1
    fi
  fi

  if is.true "${FEATURE_ASSUME_CONTAINER}"; then
    detected_container=1
  fi

  if [[ -d /etc/pve ]] || command -v pveversion >/dev/null 2>&1; then
    if ! is.true "${FEATURE_ALLOW_HOST}"; then
      log.error "This network feature must run inside a Debian LXC container, not on the Proxmox host."
      exit 1
    fi
  fi

  if is.true "${FEATURE_REQUIRE_CONTAINER}" && ((detected_container == 0)); then
    log.error "Container execution could not be confirmed. Re-run with PROXMOX_LXC_NETWORK_ASSUME_CONTAINER=1 only if you are already inside the LXC."
    exit 1
  fi
}

parse.allow.subnets() {
  local raw="${1:-}"
  NETWORK_ALLOW_SUBNET_LIST=()
  for entry in ${raw}; do
    NETWORK_ALLOW_SUBNET_LIST+=("${entry}")
  done

  if ((${#NETWORK_ALLOW_SUBNET_LIST[@]} == 0)); then
    NETWORK_ALLOW_SUBNET_LIST=("10.0.0.0/24" "192.168.0.0/16")
  fi
}

parse.access.users() {
  local raw="${1:-}"
  NETWORK_ACCESS_USERS=()
  for entry in ${raw}; do
    NETWORK_ACCESS_USERS+=("${entry}")
  done

  if ((${#NETWORK_ACCESS_USERS[@]} == 0)); then
    NETWORK_ACCESS_USERS=("agent" "proxmox" "root")
  fi
}

detect.container.identity() {
  CONTAINER_HOSTNAME="$(hostname)"
  CONTAINER_DEFAULT_ROUTE="$(ip route show default 2>/dev/null | awk 'NR==1 {print $3 " dev " $5}')"
  mapfile -t CONTAINER_IPV4 < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2 "="$4}')
}

collect.operator.selection() {
  if is.true "${FEATURE_INTERACTIVE}" && open.tty; then
    local profile_choice
    printf '\nDetected container:\n' >&3
    printf '  hostname: %s\n' "${CONTAINER_HOSTNAME}" >&3
    printf '  Debian:   %s\n' "${CONTAINER_OS_PRETTY}" >&3
    if [[ -n "${CONTAINER_CTID}" || -n "${CONTAINER_CTNAME}" ]]; then
      printf '  CTID/Name: %s %s\n' "$(yaml.scalar.or.null "${CONTAINER_CTID}")" "$(yaml.scalar.or.null "${CONTAINER_CTNAME}")" >&3
    fi
    printf '  mode:     %s\n\n' "${FEATURE_MODE}" >&3

    profile_choice="$(menu.tty 'Access profile' 'local_only' 'test_access' 'builder')"
    case "${profile_choice}" in
      1) FEATURE_ACCESS_PROFILE="local_only" ;;
      2) FEATURE_ACCESS_PROFILE="test_access" ;;
      3) FEATURE_ACCESS_PROFILE="builder" ;;
    esac

    FEATURE_ENABLE_SSH="$(prompt.tty 'Enable SSH access?' "$(
      if is.true "${FEATURE_ENABLE_SSH}"; then
        echo yes
      else
        echo no
      fi
    )")"
    FEATURE_ENABLE_UFW="$(prompt.tty 'Enable UFW and restrict SSH to local subnets?' "$(
      if is.true "${FEATURE_ENABLE_UFW}"; then
        echo yes
      else
        echo no
      fi
    )")"
    FEATURE_ENABLE_FUSE_CLIENT="$(prompt.tty 'Enable FUSE client tooling (sshfs/cifs/nfs)?' "$(
      if is.true "${FEATURE_ENABLE_FUSE_CLIENT}"; then
        echo yes
      else
        echo no
      fi
    )")"
    FEATURE_ENABLE_AVAHI="$(prompt.tty 'Enable avahi-daemon for local .local discovery?' "$(
      if is.true "${FEATURE_ENABLE_AVAHI}"; then
        echo yes
      else
        echo no
      fi
    )")"
    FEATURE_ALLOW_SUBNETS="$(prompt.tty 'Allowed local subnets for SSH (space-separated CIDR)' "${FEATURE_ALLOW_SUBNETS}")"
    FEATURE_ACCESS_USERS="$(prompt.tty 'Access users (space-separated)' "${FEATURE_ACCESS_USERS}")"
    FEATURE_INTERNET_PROBE_IPV4="$(prompt.tty 'Internet IPv4 probe target' "${FEATURE_INTERNET_PROBE_IPV4}")"
    FEATURE_EXPECTED_DNS="$(prompt.tty 'Expected DNS resolver (quick check)' "${FEATURE_EXPECTED_DNS}")"
  fi

  if is.true "${FEATURE_ENABLE_SSH}"; then
    FEATURE_ENABLE_SSH=1
  else
    FEATURE_ENABLE_SSH=0
  fi
  if is.true "${FEATURE_ENABLE_UFW}"; then
    FEATURE_ENABLE_UFW=1
  else
    FEATURE_ENABLE_UFW=0
  fi
  if is.true "${FEATURE_ENABLE_FUSE_CLIENT}"; then
    FEATURE_ENABLE_FUSE_CLIENT=1
  else
    FEATURE_ENABLE_FUSE_CLIENT=0
  fi
  if is.true "${FEATURE_ENABLE_AVAHI}"; then
    FEATURE_ENABLE_AVAHI=1
  else
    FEATURE_ENABLE_AVAHI=0
  fi

  if [[ "${FEATURE_ACCESS_PROFILE}" == "test_access" ]]; then
    FEATURE_ENABLE_SSH=1
  fi
  if [[ "${FEATURE_ACCESS_PROFILE}" == "builder" ]]; then
    FEATURE_ENABLE_SSH=1
    FEATURE_ENABLE_UFW=1
    FEATURE_ENABLE_FUSE_CLIENT=1
    FEATURE_ENABLE_AVAHI=1
  fi

  parse.allow.subnets "${FEATURE_ALLOW_SUBNETS}"
  parse.access.users "${FEATURE_ACCESS_USERS}"

  if ((${#NETWORK_ACCESS_USERS[@]} == 0)); then
    NETWORK_ACCESS_USERS=("agent" "proxmox" "root")
  fi
}

write.selection.file() {
  mkdir -p "${FACTS_DIR}"
  cat > "${NETWORK_SELECTION_PATH}" <<EOF
---
proxmox_lxc_network_operator_selection:
  confirmed: true
  source: "setup/lxc/network.sh"
  mode: $(yaml.quote "${FEATURE_MODE}")
  container:
    hostname: $(yaml.scalar.or.null "${CONTAINER_HOSTNAME}")
    ctid: $(yaml.scalar.or.null "${CONTAINER_CTID}")
    name: $(yaml.scalar.or.null "${CONTAINER_CTNAME}")
    default_route: $(yaml.scalar.or.null "${CONTAINER_DEFAULT_ROUTE}")
    ipv4:
$(for entry in "${CONTAINER_IPV4[@]:-}"; do printf '      - %s\n' "$(yaml.quote "${entry}")"; done)
  hardening:
    access_profile: $(yaml.quote "${FEATURE_ACCESS_PROFILE}")
    enable_ssh: $(bool.yaml "${FEATURE_ENABLE_SSH}")
    enable_ufw: $(bool.yaml "${FEATURE_ENABLE_UFW}")
    enable_fuse_client: $(bool.yaml "${FEATURE_ENABLE_FUSE_CLIENT}")
    enable_avahi: $(bool.yaml "${FEATURE_ENABLE_AVAHI}")
    access_users:
$(for user in "${NETWORK_ACCESS_USERS[@]}"; do printf '      - %s\n' "$(yaml.quote "${user}")"; done)
    allow_subnets:
$(for subnet in "${NETWORK_ALLOW_SUBNET_LIST[@]}"; do printf '      - %s\n' "$(yaml.quote "${subnet}")"; done)
    expected_dns: $(yaml.quote "${FEATURE_EXPECTED_DNS}")
    internet_probe_ipv4: $(yaml.quote "${FEATURE_INTERNET_PROBE_IPV4}")
    ssh:
      port: "${FEATURE_SSH_PORT}"
EOF
}

write.network.extra.vars.file() {
  mkdir -p "${TMP_DIR}"
  cat > "${NETWORK_EXTRA_VARS_PATH}" <<EOF
---
proxmox_feature_defaults:
  lxc_network:
    enabled: true
    mode: $(yaml.quote "${FEATURE_MODE}")
    require_container: $(bool.yaml "${FEATURE_REQUIRE_CONTAINER}")
    require_operator_selection: true

proxmox_feature_facts_dir: $(yaml.quote "${FACTS_DIR}")
proxmox_lxc_network:
  facts_dir: $(yaml.quote "${FACTS_DIR}")
  container_facts_path: $(yaml.quote "${NETWORK_CONTAINER_FACTS_PATH}")
  runtime_facts_path: $(yaml.quote "${NETWORK_RUNTIME_FACTS_PATH}")
  selection_path: $(yaml.quote "${NETWORK_SELECTION_PATH}")
  hardening:
    access_profile: $(yaml.quote "${FEATURE_ACCESS_PROFILE}")
    enable_ssh: $(bool.yaml "${FEATURE_ENABLE_SSH}")
    enable_ufw: $(bool.yaml "${FEATURE_ENABLE_UFW}")
    enable_fuse_client: $(bool.yaml "${FEATURE_ENABLE_FUSE_CLIENT}")
    enable_avahi: $(bool.yaml "${FEATURE_ENABLE_AVAHI}")
    access_users:
$(for user in "${NETWORK_ACCESS_USERS[@]}"; do printf '      - %s\n' "$(yaml.quote "${user}")"; done)
    allow_subnets:
$(for subnet in "${NETWORK_ALLOW_SUBNET_LIST[@]}"; do printf '      - %s\n' "$(yaml.quote "${subnet}")"; done)
    expected_dns: $(yaml.quote "${FEATURE_EXPECTED_DNS}")
    internet_probe_ipv4: $(yaml.quote "${FEATURE_INTERNET_PROBE_IPV4}")
  ssh:
    include_path: "/etc/ssh/sshd_config.d/90-proxmox-lxc-network.conf"
    port: "${FEATURE_SSH_PORT}"
    permit_root_login: "yes"
    password_authentication: "yes"
    kbd_interactive_authentication: "no"
    use_pam: "yes"
    x11_forwarding: "no"
    pubkey_authentication: null
  optional_packages:
    avahi:
      enabled: $(bool.yaml "${FEATURE_ENABLE_AVAHI}")
EOF
  log "Prepared LXC network extra-vars: ${NETWORK_EXTRA_VARS_PATH}"
}

write.container.facts() {
  mkdir -p "${FACTS_DIR}"
  cat > "${NETWORK_CONTAINER_FACTS_PATH}" <<EOF
---
proxmox_lxc_network_container:
  hostname: $(yaml.quote "${CONTAINER_HOSTNAME}")
  ctid: $(yaml.scalar.or.null "${CONTAINER_CTID}")
  name: $(yaml.scalar.or.null "${CONTAINER_CTNAME}")
  os_pretty_name: $(yaml.quote "${CONTAINER_OS_PRETTY}")
  default_route: $(yaml.scalar.or.null "${CONTAINER_DEFAULT_ROUTE}")
  ipv4:
$(for entry in "${CONTAINER_IPV4[@]:-}"; do printf '    - %s\n' "$(yaml.quote "${entry}")"; done)
EOF
}

use.local.feature.files() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/../.." && pwd)"

  if [[ -r "${repo_root}/ansible/${NETWORK_PLAYBOOK_REL}" && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]]; then
    PLAYBOOK_ROOT="${repo_root}/ansible"
    PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
    GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
    NETWORK_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NETWORK_PLAYBOOK_REL}"
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
  fetch.feature.file "${NETWORK_PLAYBOOK_URL}" "${NETWORK_PLAYBOOK_PATH}"
}

run.feature.playbook() {
  local playbook_path="$1"
  shift
  "${ANSIBLE_VENV_BIN}" -i localhost, -c local -e "@${GROUP_VARS_PATH}" "$@" "${playbook_path}"
}

run.network.feature() {
  detect.container.identity
  collect.operator.selection
  write.container.facts
  write.selection.file
  write.network.extra.vars.file

  if [[ "${FEATURE_ACCESS_PROFILE}" == "test_access" ]]; then
    log "test_access profile enabled. Default password policy: each access user => <user>:<user>."
  fi

  log "Running LXC network feature in mode=${FEATURE_MODE}..."
  run.feature.playbook "${NETWORK_PLAYBOOK_PATH}" -e "@${NETWORK_EXTRA_VARS_PATH}"
}

main() {
  require.root
  require.apt
  require.valid.mode
  detect.container.identity
  require.debian.container
  require.container.not.host
  ensure.container.ansible
  prepare.feature.files
  run.network.feature
}

main "$@"
