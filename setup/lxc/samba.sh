#!/usr/bin/env bash
## Manual Proxmox LXC Samba feature runner.
## Local usage:
##   ./setup/lxc/samba.sh [preflight|apply]
## Published usage:
##   wget -qO- https://devs-guide.github.io/proxmox/setup/lxc/samba.sh | bash

set -euo pipefail

log()       { printf '[setup.lxc.samba] %s\n' "$*" >&2; }
log.error() { printf '[setup.lxc.samba][error] %s\n' "$*" >&2; }
log.warn()  { printf '[setup.lxc.samba][warn] %s\n' "$*" >&2; }

TMP_DIR="/tmp/pve-feature-samba"
PAGES_BASE_URL="https://devs-guide.github.io/proxmox"
PLAYBOOK_ROOT="${TMP_DIR}/ansible"
PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
LOCAL_COMMON_HELPER="../../bootstrap/release.common.sh"
COMMON_HELPER_NAME="release.common.sh"
COMMON_HELPER_URL="${PAGES_BASE_URL}/${COMMON_HELPER_NAME}"
COMMON_HELPER_PATH="${TMP_DIR}/${COMMON_HELPER_NAME}"
LXC_COMMON_HELPER_NAME="common.sh"
GROUP_VARS_FILE="proxmox.yml"
GROUP_VARS_URL="${PAGES_BASE_URL}/ansible/group_vars/${GROUP_VARS_FILE}"
GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
FEATURE_PLAYBOOKS=(
  "proxmox/container/samba.file.share.yml"
)
SAMBA_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[0]}"
SAMBA_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${SAMBA_PLAYBOOK_REL}"
SAMBA_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${SAMBA_PLAYBOOK_REL}"
SAMBA_EXTRA_VARS_PATH="${TMP_DIR}/samba.extra-vars.yml"
ANSIBLE_VENV="/opt/ansible-venv"
ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
ANSIBLE_CORE_VERSION="${PROXMOX_BOOTSTRAP_ANSIBLE_CORE_VERSION:-2.20.5}"
ANSIBLE_CORE_SPEC="ansible-core==${ANSIBLE_CORE_VERSION}"
PROXMOX_RUNTIME_CONTEXT="container"
FACTS_DIR="${PROXMOX_SAMBA_FACTS_DIR:-/etc/ansible/proxmox/facts}"
CONTAINER_FACTS_PATH="${PROXMOX_SAMBA_CONTAINER_FACTS_PATH:-${FACTS_DIR}/container.yml}"
SAMBA_FACTS_PATH="${PROXMOX_SAMBA_RUNTIME_FACTS_PATH:-${FACTS_DIR}/samba.yml}"
SAMBA_MOUNTS_TSV="${PROXMOX_SAMBA_MOUNTS_TSV:-${FACTS_DIR}/samba.mounts.tsv}"
SAMBA_SELECTION_PATH="${PROXMOX_SAMBA_SELECTION_PATH:-${FACTS_DIR}/samba.selection.yml}"
FEATURE_MODE="${1:-${PROXMOX_SAMBA_MODE:-apply}}"
FEATURE_INTERACTIVE="${PROXMOX_SAMBA_INTERACTIVE:-1}"
FEATURE_REQUIRE_CONTAINER="${PROXMOX_SAMBA_REQUIRE_CONTAINER:-1}"
FEATURE_ALLOW_HOST="${PROXMOX_SAMBA_ALLOW_HOST:-0}"
FEATURE_ASSUME_CONTAINER="${PROXMOX_SAMBA_ASSUME_CONTAINER:-0}"
PROXMOX_SAMBA_ENABLE_UFW="${PROXMOX_SAMBA_ENABLE_UFW:-1}"
PROXMOX_SAMBA_ENABLE_SSH="${PROXMOX_SAMBA_ENABLE_SSH:-0}"
PROXMOX_SAMBA_ENABLE_AVAHI="${PROXMOX_SAMBA_ENABLE_AVAHI:-0}"
PROXMOX_SAMBA_REQUIRE_XATTR="${PROXMOX_SAMBA_REQUIRE_XATTR:-0}"
PROXMOX_SAMBA_WORKGROUP="${PROXMOX_SAMBA_WORKGROUP:-WORKGROUP}"
PROXMOX_SAMBA_NETBIOS_NAME="${PROXMOX_SAMBA_NETBIOS_NAME:-}"
PROXMOX_SAMBA_MAP_TO_GUEST="${PROXMOX_SAMBA_MAP_TO_GUEST:-Bad User}"
PROXMOX_SAMBA_GUEST_ACCOUNT="${PROXMOX_SAMBA_GUEST_ACCOUNT:-nobody}"
PROXMOX_SAMBA_FORCE_USER="${PROXMOX_SAMBA_FORCE_USER:-smb-ingest}"
PROXMOX_SAMBA_FORCE_GROUP="${PROXMOX_SAMBA_FORCE_GROUP:-smb-ingest}"
PROXMOX_SAMBA_GUEST_MODE="${PROXMOX_SAMBA_GUEST_MODE:-1}"
PROXMOX_SAMBA_PROFILE="${PROXMOX_SAMBA_PROFILE:-modern_mac}"
PROXMOX_SAMBA_ALLOW_SUBNETS="${PROXMOX_SAMBA_ALLOW_SUBNETS:-}"
PROXMOX_SAMBA_DATA_INTERFACE="${PROXMOX_SAMBA_DATA_INTERFACE:-}"
PROXMOX_SAMBA_EGRESS_INTERFACE="${PROXMOX_SAMBA_EGRESS_INTERFACE:-}"
PROXMOX_SAMBA_DNS_SERVERS="${PROXMOX_SAMBA_DNS_SERVERS:-}"
PROXMOX_SAMBA_CREDENTIAL_MODE="${PROXMOX_SAMBA_CREDENTIAL_MODE:-}"
PROXMOX_SAMBA_AUTH_USER="${PROXMOX_SAMBA_AUTH_USER:-}"
PROXMOX_SAMBA_AUTH_PASSWORD="${PROXMOX_SAMBA_AUTH_PASSWORD:-}"
# Backward-compatible alias for callers that opted into the earlier hidden
# hostname-password switch. New callers should select credential_mode=hostname.
PROXMOX_SAMBA_ALLOW_HOSTNAME_PASSWORD="${PROXMOX_SAMBA_ALLOW_HOSTNAME_PASSWORD:-0}"
PROXMOX_SAMBA_SHARE_PATHS="${PROXMOX_SAMBA_SHARE_PATHS:-}"
PROXMOX_SAMBA_SHARE_NAME="${PROXMOX_SAMBA_SHARE_NAME:-}"
PROXMOX_SAMBA_ALLOW_EMPTY_SHARES="${PROXMOX_SAMBA_ALLOW_EMPTY_SHARES:-0}"
# Two-tier baseline policy for this stack:
# - Generic LXC common baseline: root, app, agent
# Common baseline is shared with all non-project LXC runners.
PROXMOX_SAMBA_BASELINE_USERS="${PROXMOX_SAMBA_BASELINE_USERS:-${PROXMOX_LXC_COMMON_BASELINE_USERS:-root app agent}}"
PROXMOX_SAMBA_ALLOW_USERS="${PROXMOX_SAMBA_ALLOW_USERS:-}"
PROXMOX_SAMBA_ALLOW_USERS_OVERRIDE="${PROXMOX_SAMBA_ALLOW_USERS_OVERRIDE:-false}"
if [[ -n "${PROXMOX_SAMBA_ALLOW_USERS:-}" ]]; then
  PROXMOX_SAMBA_ALLOW_USERS_OVERRIDE="true"
fi
SAMBA_SELF_URL="${PROXMOX_SAMBA_SELF_URL:-${PAGES_BASE_URL}/setup/lxc/samba.sh}"
SAMBA_SUDO_REEXEC="${PROXMOX_SAMBA_SUDO_REEXEC:-0}"

declare -a MOUNT_PATH=()
declare -a PROXMOX_SAMBA_ALLOW_USERS_SELECTED=()
declare -a PROXMOX_SAMBA_ALLOW_USERS_CLI=()
declare -a MOUNT_SOURCE=()
declare -a MOUNT_FSTYPE=()
declare -a MOUNT_OPTIONS=()
declare -a MOUNT_READABLE=()
declare -a MOUNT_WRITABLE=()
declare -a MOUNT_XATTR=()
declare -a MOUNT_SHARE_NAME=()
declare -a SELECTED_SHARES=()
declare -a ALLOW_SUBNET_LIST=()
declare -a CONTAINER_IPV4=()
declare -a CONTAINER_IFACES=()
declare -a PARSED_SHARE_INDEXES=()

CONTAINER_HOSTNAME=""
CONTAINER_DEFAULT_ROUTE=""
CONTAINER_OS_PRETTY=""
CONTAINER_CTID="${PROXMOX_CTID:-}"
CONTAINER_CTNAME="${PROXMOX_CTNAME:-}"
OPEN_TTY=0
ALLOW_EMPTY_SHARES="false"
SHARE_SELECTION_ERROR=""

remove.samba.secret.file() {
  if [[ -n "${SAMBA_EXTRA_VARS_PATH:-}" && -f "${SAMBA_EXTRA_VARS_PATH}" ]]; then
    rm -f -- "${SAMBA_EXTRA_VARS_PATH}" || true
  fi
}

cleanup.samba.secrets() {
  local exit_code=$?
  set +e
  remove.samba.secret.file
  PROXMOX_SAMBA_AUTH_PASSWORD=""
  return "${exit_code}"
}

trap cleanup.samba.secrets EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

source.lxc.common() {
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  if [[ -n "${script_dir}" && -r "${script_dir}/${LXC_COMMON_HELPER_NAME}" ]]; then
    # shellcheck source=common.sh
    source "${script_dir}/${LXC_COMMON_HELPER_NAME}"
    return
  fi

  mkdir -p "${TMP_DIR}"
  if ! wget -qO "${TMP_DIR}/${LXC_COMMON_HELPER_NAME}" "${PAGES_BASE_URL}/setup/lxc/${LXC_COMMON_HELPER_NAME}"; then
    log.error "Unable to fetch shared LXC baseline helper from ${PAGES_BASE_URL}/setup/lxc/${LXC_COMMON_HELPER_NAME}; confirm setup/lxc/common.sh is published"
    exit 1
  fi

  if [[ -r "${TMP_DIR}/${LXC_COMMON_HELPER_NAME}" ]]; then
    # shellcheck source=common.sh
    source "${TMP_DIR}/${LXC_COMMON_HELPER_NAME}"
    return
  fi

  log.error "Shared LXC baseline helper is missing: ${script_dir}/${LXC_COMMON_HELPER_NAME}"
  exit 1
}

source.lxc.common

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
  # shellcheck source=/tmp/pve-feature-samba/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

source.release.common

collect.sudo.env.args() {
  local -n _out="$1"

  _out=(
    "PROXMOX_SAMBA_MODE=${FEATURE_MODE}"
    "PROXMOX_SAMBA_INTERACTIVE=${FEATURE_INTERACTIVE}"
    "PROXMOX_SAMBA_REQUIRE_CONTAINER=${FEATURE_REQUIRE_CONTAINER}"
    "PROXMOX_SAMBA_ALLOW_HOST=${FEATURE_ALLOW_HOST}"
    "PROXMOX_SAMBA_ASSUME_CONTAINER=${FEATURE_ASSUME_CONTAINER}"
    "PROXMOX_SAMBA_ENABLE_UFW=${PROXMOX_SAMBA_ENABLE_UFW}"
    "PROXMOX_SAMBA_ENABLE_SSH=${PROXMOX_SAMBA_ENABLE_SSH}"
    "PROXMOX_SAMBA_ENABLE_AVAHI=${PROXMOX_SAMBA_ENABLE_AVAHI}"
    "PROXMOX_SAMBA_REQUIRE_XATTR=${PROXMOX_SAMBA_REQUIRE_XATTR}"
    "PROXMOX_SAMBA_WORKGROUP=${PROXMOX_SAMBA_WORKGROUP}"
    "PROXMOX_SAMBA_NETBIOS_NAME=${PROXMOX_SAMBA_NETBIOS_NAME}"
    "PROXMOX_SAMBA_MAP_TO_GUEST=${PROXMOX_SAMBA_MAP_TO_GUEST}"
    "PROXMOX_SAMBA_GUEST_ACCOUNT=${PROXMOX_SAMBA_GUEST_ACCOUNT}"
    "PROXMOX_SAMBA_FORCE_USER=${PROXMOX_SAMBA_FORCE_USER}"
    "PROXMOX_SAMBA_FORCE_GROUP=${PROXMOX_SAMBA_FORCE_GROUP}"
    "PROXMOX_SAMBA_GUEST_MODE=${PROXMOX_SAMBA_GUEST_MODE}"
    "PROXMOX_SAMBA_PROFILE=${PROXMOX_SAMBA_PROFILE}"
    "PROXMOX_SAMBA_ALLOW_SUBNETS=${PROXMOX_SAMBA_ALLOW_SUBNETS}"
    "PROXMOX_SAMBA_DATA_INTERFACE=${PROXMOX_SAMBA_DATA_INTERFACE}"
    "PROXMOX_SAMBA_EGRESS_INTERFACE=${PROXMOX_SAMBA_EGRESS_INTERFACE}"
    "PROXMOX_SAMBA_DNS_SERVERS=${PROXMOX_SAMBA_DNS_SERVERS}"
    "PROXMOX_SAMBA_CREDENTIAL_MODE=${PROXMOX_SAMBA_CREDENTIAL_MODE}"
    "PROXMOX_SAMBA_AUTH_USER=${PROXMOX_SAMBA_AUTH_USER}"
    "PROXMOX_SAMBA_ALLOW_HOSTNAME_PASSWORD=${PROXMOX_SAMBA_ALLOW_HOSTNAME_PASSWORD}"
    "PROXMOX_SAMBA_SHARE_PATHS=${PROXMOX_SAMBA_SHARE_PATHS}"
    "PROXMOX_SAMBA_ALLOW_EMPTY_SHARES=${PROXMOX_SAMBA_ALLOW_EMPTY_SHARES}"
    "PROXMOX_SAMBA_ALLOW_USERS_OVERRIDE=${PROXMOX_SAMBA_ALLOW_USERS_OVERRIDE}"
    "PROXMOX_SAMBA_FACTS_DIR=${FACTS_DIR}"
    "PROXMOX_SAMBA_CONTAINER_FACTS_PATH=${CONTAINER_FACTS_PATH}"
    "PROXMOX_SAMBA_RUNTIME_FACTS_PATH=${SAMBA_FACTS_PATH}"
    "PROXMOX_SAMBA_MOUNTS_TSV=${SAMBA_MOUNTS_TSV}"
    "PROXMOX_SAMBA_SELECTION_PATH=${SAMBA_SELECTION_PATH}"
    "PROXMOX_CTID=${CONTAINER_CTID}"
    "PROXMOX_CTNAME=${CONTAINER_CTNAME}"
    "PROXMOX_SAMBA_SELF_URL=${SAMBA_SELF_URL}"
    "PROXMOX_SAMBA_SUDO_REEXEC=1"
    "PAGES_BASE_URL=${PAGES_BASE_URL}"
    "TMP_DIR=${TMP_DIR}"
  )

  if is.true "${PROXMOX_SAMBA_ALLOW_USERS_OVERRIDE}" && [[ -n "${PROXMOX_SAMBA_ALLOW_USERS:-}" ]]; then
    _out+=("PROXMOX_SAMBA_ALLOW_USERS=${PROXMOX_SAMBA_ALLOW_USERS}")
  fi
}

is.true() {
  local value="${1:-}"
  case "${value,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
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

prompt.secret.tty() {
  local prompt="$1" answer=""
  printf '%s: ' "${prompt}" >&3
  read -r -s -u 3 answer || true
  printf '\n' >&3
  printf '%s' "${answer}"
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

require.valid.mode() {
  case "${FEATURE_MODE}" in
    preflight|apply) ;;
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
      log.error "This Samba feature must be run inside the NAS LXC container, not on the Proxmox host."
      exit 1
    fi
  fi

  if is.true "${FEATURE_REQUIRE_CONTAINER}" && ((detected_container == 0)); then
    log.error "Container execution could not be confirmed. Re-run with PROXMOX_SAMBA_ASSUME_CONTAINER=1 only if you are already inside the LXC."
    exit 1
  fi
}

normalize.share.name() {
  local path="$1"
  local name
  name="$(basename "${path}")"
  name="${name// /_}"
  name="${name//-/_}"
  name="$(printf '%s' "${name}" | tr '[:lower:]' '[:upper:]')"
  name="$(printf '%s' "${name}" | sed 's/[^A-Z0-9_]/_/g; s/__\+/_/g; s/^_//; s/_$//')"
  printf '%s\n' "${name:-SHARE}"
}

path.is.excluded() {
  local path="$1"
  case "${path}" in
    /|/boot|/dev|/etc|/proc|/run|/sys|/tmp|/var) return 0 ;;
  esac
  return 1
}

path.is.included_root() {
  local path="$1"
  case "${path}" in
    /media/*|/mnt/*|/srv/storage/*|/storage/*) return 0 ;;
    *) return 1 ;;
  esac
}

fstype.is.excluded() {
  local fstype="$1"
  case "${fstype}" in
    proc|sysfs|devtmpfs|devpts|tmpfs|cgroup|cgroup2|overlay|squashfs|autofs|securityfs|debugfs|tracefs|fusectl|pstore)
      return 0
      ;;
  esac
  return 1
}

detect.container.identity() {
  CONTAINER_HOSTNAME="$(hostname)"
  CONTAINER_DEFAULT_ROUTE="$(ip route show default 2>/dev/null | awk 'NR==1 {print $3 " dev " $5}')"
  mapfile -t CONTAINER_IPV4 < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2 "=" $4}')
  mapfile -t CONTAINER_IFACES < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}' | sort -u)
  if [[ -z "${PROXMOX_SAMBA_EGRESS_INTERFACE}" ]]; then
    PROXMOX_SAMBA_EGRESS_INTERFACE="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  fi
  if [[ -z "${PROXMOX_SAMBA_DNS_SERVERS}" ]]; then
    PROXMOX_SAMBA_DNS_SERVERS="$(awk '$1 == "nameserver" && $2 ~ /^[0-9.]+$/ {print $2}' /etc/resolv.conf 2>/dev/null | sort -u | paste -sd' ' -)"
  fi
}

normalize.credential.mode() {
  if [[ -z "${PROXMOX_SAMBA_CREDENTIAL_MODE}" ]]; then
    if is.true "${PROXMOX_SAMBA_ALLOW_HOSTNAME_PASSWORD}"; then
      PROXMOX_SAMBA_CREDENTIAL_MODE="hostname"
    elif [[ -n "${PROXMOX_SAMBA_AUTH_USER}" || -n "${PROXMOX_SAMBA_AUTH_PASSWORD}" ]]; then
      PROXMOX_SAMBA_CREDENTIAL_MODE="custom"
    else
      PROXMOX_SAMBA_CREDENTIAL_MODE="hostname"
    fi
  fi

  case "${PROXMOX_SAMBA_CREDENTIAL_MODE}" in
    hostname|custom) ;;
    *)
      log.error "Unsupported Samba credential mode: ${PROXMOX_SAMBA_CREDENTIAL_MODE}"
      log.error "Use one of: hostname, custom"
      exit 1
      ;;
  esac
}

select.samba.credentials() {
  local credential_choice="" password_confirm=""

  normalize.credential.mode

  if is.true "${FEATURE_INTERACTIVE}" && ((OPEN_TTY == 1)); then
    credential_choice="$(menu.tty \
      'Authenticated SMB credential mode' \
      "LXC hostname compatibility (${CONTAINER_HOSTNAME}/${CONTAINER_HOSTNAME})" \
      'custom username and password')"
    case "${credential_choice}" in
      1) PROXMOX_SAMBA_CREDENTIAL_MODE="hostname" ;;
      2) PROXMOX_SAMBA_CREDENTIAL_MODE="custom" ;;
    esac
  fi

  case "${PROXMOX_SAMBA_CREDENTIAL_MODE}" in
    hostname)
      PROXMOX_SAMBA_AUTH_USER="${CONTAINER_HOSTNAME}"
      PROXMOX_SAMBA_AUTH_PASSWORD=""
      if [[ "${FEATURE_MODE}" == apply ]]; then
        PROXMOX_SAMBA_AUTH_PASSWORD="${CONTAINER_HOSTNAME}"
        log.warn "Using the LXC hostname as the compatibility Samba username and password; select custom mode to supply separate credentials."
      fi
      ;;
    custom)
      if is.true "${FEATURE_INTERACTIVE}" && ((OPEN_TTY == 1)); then
        PROXMOX_SAMBA_AUTH_USER="$(prompt.tty 'Enter authenticated SMB username' "${PROXMOX_SAMBA_AUTH_USER}")"
        if [[ "${FEATURE_MODE}" == apply && -z "${PROXMOX_SAMBA_AUTH_PASSWORD}" ]]; then
          PROXMOX_SAMBA_AUTH_PASSWORD="$(prompt.secret.tty 'Enter authenticated SMB password')"
          password_confirm="$(prompt.secret.tty 'Confirm authenticated SMB password')"
          [[ "${PROXMOX_SAMBA_AUTH_PASSWORD}" == "${password_confirm}" ]] \
            || { log.error 'SMB passwords did not match.'; exit 1; }
        fi
      fi
      ;;
  esac

  [[ "${PROXMOX_SAMBA_AUTH_USER}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] \
    || { log.error 'Select a valid lowercase SMB username.'; exit 1; }
  [[ "${PROXMOX_SAMBA_AUTH_USER}" != "${PROXMOX_SAMBA_FORCE_USER}" \
    && "${PROXMOX_SAMBA_AUTH_USER}" != "${PROXMOX_SAMBA_GUEST_ACCOUNT}" ]] \
    || { log.error 'The authenticated SMB user must differ from the force and guest identities.'; exit 1; }
  if [[ "${FEATURE_MODE}" == apply && -z "${PROXMOX_SAMBA_AUTH_PASSWORD}" ]]; then
    log.error 'Custom apply requires an interactively entered secret or PROXMOX_SAMBA_AUTH_PASSWORD.'
    exit 1
  fi
}

select.network.roles() {
  local candidate="" candidate_count=0 selected="" data_cidr=""
  if [[ -z "${PROXMOX_SAMBA_DATA_INTERFACE}" ]]; then
    for candidate in "${CONTAINER_IFACES[@]}"; do
      [[ "${candidate}" != "${PROXMOX_SAMBA_EGRESS_INTERFACE}" ]] || continue
      selected="${candidate}"
      candidate_count=$((candidate_count + 1))
    done
    if ((candidate_count == 1)); then
      PROXMOX_SAMBA_DATA_INTERFACE="${selected}"
    fi
  fi

  if is.true "${FEATURE_INTERACTIVE}" && open.tty; then
    printf '\nDiscovered container network roles:\n' >&3
    printf '  egress/default-route interface: %s\n' "${PROXMOX_SAMBA_EGRESS_INTERFACE:-none}" >&3
    printf '  interfaces with global IPv4: %s\n' "${CONTAINER_IFACES[*]:-none}" >&3
    PROXMOX_SAMBA_DATA_INTERFACE="$(prompt.tty "Enter SMB data interface" "${PROXMOX_SAMBA_DATA_INTERFACE}")"
  fi

  [[ -n "${PROXMOX_SAMBA_DATA_INTERFACE}" ]] || { log.error "A discovered/operator-selected SMB data interface is required."; exit 1; }
  [[ "${PROXMOX_SAMBA_DATA_INTERFACE}" != "${PROXMOX_SAMBA_EGRESS_INTERFACE}" ]] || { log.error "SMB data and Internet egress interfaces must differ."; exit 1; }
  ip link show dev "${PROXMOX_SAMBA_DATA_INTERFACE}" >/dev/null 2>&1 || { log.error "Data interface does not exist: ${PROXMOX_SAMBA_DATA_INTERFACE}"; exit 1; }

  if [[ -z "${PROXMOX_SAMBA_ALLOW_SUBNETS}" ]]; then
    data_cidr="$(ip -4 route show dev "${PROXMOX_SAMBA_DATA_INTERFACE}" proto kernel scope link 2>/dev/null | awk 'NR==1 {print $1}')"
    PROXMOX_SAMBA_ALLOW_SUBNETS="${data_cidr}"
  fi
  [[ -n "${PROXMOX_SAMBA_ALLOW_SUBNETS}" ]] || { log.error "Could not discover the local SMB data CIDR."; exit 1; }
  select.samba.credentials
}

write.container.facts() {
  mkdir -p "${FACTS_DIR}"
  cat > "${CONTAINER_FACTS_PATH}" <<EOF
---
proxmox_container_runtime:
  hostname: $(yaml.quote "${CONTAINER_HOSTNAME}")
  ctid: $(yaml.scalar.or.null "${CONTAINER_CTID}")
  name: $(yaml.scalar.or.null "${CONTAINER_CTNAME}")
  os_pretty_name: $(yaml.quote "${CONTAINER_OS_PRETTY}")
  default_route: $(yaml.scalar.or.null "${CONTAINER_DEFAULT_ROUTE}")
  ipv4:
$(for entry in "${CONTAINER_IPV4[@]}"; do printf '    - %s\n' "$(yaml.quote "${entry}")"; done)
EOF
}

detect.share.xattr() {
  local path="$1"
  local test_file="${path}/.proxmox-samba-xattr-test"
  if ! touch "${test_file}" >/dev/null 2>&1; then
    printf 'no\n'
    return 0
  fi
  if command -v setfattr >/dev/null 2>&1 && command -v getfattr >/dev/null 2>&1; then
    if setfattr -n user.proxmox_samba_test -v ok "${test_file}" >/dev/null 2>&1 \
      && getfattr -n user.proxmox_samba_test "${test_file}" >/dev/null 2>&1; then
      rm -f "${test_file}"
      printf 'yes\n'
      return 0
    fi
  fi
  rm -f "${test_file}"
  printf 'no\n'
}

discover.mounts() {
  local line path source fstype options readable writable xattr share_name

  MOUNT_PATH=()
  MOUNT_SOURCE=()
  MOUNT_FSTYPE=()
  MOUNT_OPTIONS=()
  MOUNT_READABLE=()
  MOUNT_WRITABLE=()
  MOUNT_XATTR=()
  MOUNT_SHARE_NAME=()

  while IFS='|' read -r path source fstype options; do
    [[ -n "${path}" ]] || continue
    path.is.excluded "${path}" && continue
    path.is.included_root "${path}" || continue
    fstype.is.excluded "${fstype}" && continue
    [[ -d "${path}" ]] || continue

    readable="no"
    writable="no"
    [[ -r "${path}" ]] && readable="yes"
    [[ -w "${path}" ]] && writable="yes"
    share_name="$(normalize.share.name "${path}")"
    xattr="$(detect.share.xattr "${path}")"

    MOUNT_PATH+=("${path}")
    MOUNT_SOURCE+=("${source:-unknown}")
    MOUNT_FSTYPE+=("${fstype:-unknown}")
    MOUNT_OPTIONS+=("${options:-unknown}")
    MOUNT_READABLE+=("${readable}")
    MOUNT_WRITABLE+=("${writable}")
    MOUNT_XATTR+=("${xattr}")
    MOUNT_SHARE_NAME+=("${share_name}")
  done < <(findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS | awk '{target=$1; source=$2; fstype=$3; $1=$2=$3=""; sub(/^ +/,""); print target "|" source "|" fstype "|" $0}')

  mkdir -p "${FACTS_DIR}"
  {
    printf 'share_name\tpath\tsource\tfstype\toptions\treadable\twritable\txattr\n'
    local i
    for i in "${!MOUNT_PATH[@]}"; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${MOUNT_SHARE_NAME[$i]}" \
        "${MOUNT_PATH[$i]}" \
        "${MOUNT_SOURCE[$i]}" \
        "${MOUNT_FSTYPE[$i]}" \
        "${MOUNT_OPTIONS[$i]}" \
        "${MOUNT_READABLE[$i]}" \
        "${MOUNT_WRITABLE[$i]}" \
        "${MOUNT_XATTR[$i]}"
    done
  } > "${SAMBA_MOUNTS_TSV}"

  log "Discovered ${#MOUNT_PATH[@]} candidate share mountpoint(s)."
}

require.unique.share.names() {
  local names joined duplicates
  names="$(printf '%s\n' "${MOUNT_SHARE_NAME[@]:-}")"
  duplicates="$(printf '%s\n' "${names}" | sort | uniq -d || true)"
  if [[ -n "${duplicates}" ]]; then
    log.error "Duplicate Samba share names detected after sanitization:"
    printf '%s\n' "${duplicates}" >&2
    exit 1
  fi
}

mount.index.by.path() {
  local path="${1:-}"
  local i
  for i in "${!MOUNT_PATH[@]}"; do
    if [[ "${MOUNT_PATH[$i]}" == "${path}" ]]; then
      printf '%s\n' "${i}"
      return 0
    fi
  done
  return 1
}

mount.readable.by.path() {
  local path="${1:-}" idx
  if idx="$(mount.index.by.path "${path}")"; then
    printf '%s\n' "${MOUNT_READABLE[$idx]}"
  else
    printf 'no\n'
  fi
}

mount.writable.by.path() {
  local path="${1:-}" idx
  if idx="$(mount.index.by.path "${path}")"; then
    printf '%s\n' "${MOUNT_WRITABLE[$idx]}"
  else
    printf 'no\n'
  fi
}

mount.xattr.by.path() {
  local path="${1:-}" idx
  if idx="$(mount.index.by.path "${path}")"; then
    printf '%s\n' "${MOUNT_XATTR[$idx]}"
  else
    printf 'no\n'
  fi
}

mount.share.name.by.path() {
  local path="${1:-}" idx
  if idx="$(mount.index.by.path "${path}")"; then
    printf '%s\n' "${MOUNT_SHARE_NAME[$idx]}"
  else
    normalize.share.name "${path}"
  fi
}

selected.share.name.by.path() {
  local path="${1:-}"
  if [[ -n "${PROXMOX_SAMBA_SHARE_NAME}" ]]; then
    printf '%s\n' "${PROXMOX_SAMBA_SHARE_NAME}"
  else
    mount.share.name.by.path "${path}"
  fi
}

select.published.share.name() {
  local default_name requested_name
  ((${#SELECTED_SHARES[@]} > 0)) || return 0

  if [[ -n "${PROXMOX_SAMBA_SHARE_NAME}" && ${#SELECTED_SHARES[@]} -ne 1 ]]; then
    log.error "PROXMOX_SAMBA_SHARE_NAME can be used only when exactly one share path is selected."
    exit 1
  fi

  if ((${#SELECTED_SHARES[@]} == 1)); then
    default_name="$(mount.share.name.by.path "${SELECTED_SHARES[0]}")"
    if is.true "${FEATURE_INTERACTIVE}" && ((OPEN_TTY == 1)); then
      requested_name="$(prompt.tty "Enter published SMB share name" "${PROXMOX_SAMBA_SHARE_NAME:-${default_name}}")"
      PROXMOX_SAMBA_SHARE_NAME="${requested_name}"
    fi
    PROXMOX_SAMBA_SHARE_NAME="$(normalize.share.name "${PROXMOX_SAMBA_SHARE_NAME:-${default_name}}")"
  fi
}

append.share.selection.index() {
  local candidate="$1"
  local existing
  for existing in "${PARSED_SHARE_INDEXES[@]:-}"; do
    [[ "${existing}" == "${candidate}" ]] && return 0
  done
  PARSED_SHARE_INDEXES+=("${candidate}")
}

parse.share.selection() {
  local raw="${1:-}"
  local token value start end current
  local count="${#MOUNT_PATH[@]}"
  local -a share_selection_tokens=()

  PARSED_SHARE_INDEXES=()
  SHARE_SELECTION_ERROR=""

  raw="$(printf '%s' "${raw}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [[ -z "${raw}" || "${raw^^}" == "NONE" ]]; then
    return 0
  fi

  if [[ "${raw^^}" == "ALL" ]]; then
    for current in "${!MOUNT_PATH[@]}"; do
      PARSED_SHARE_INDEXES+=("${current}")
    done
    return 0
  fi

  raw="${raw//[[:space:]]/}"
  IFS=',' read -r -a share_selection_tokens <<< "${raw}"
  for token in "${share_selection_tokens[@]}"; do
    if [[ -z "${token}" ]]; then
      SHARE_SELECTION_ERROR="Empty selection token is not valid."
      return 1
    fi
    if [[ "${token}" =~ ^[0-9]+$ ]]; then
      value="${token}"
      if ((value < 1 || value > count)); then
        SHARE_SELECTION_ERROR="Selection ${value} is out of range."
        return 1
      fi
      append.share.selection.index "$((value - 1))"
      continue
    fi
    if [[ "${token}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if ((start > end)); then
        SHARE_SELECTION_ERROR="Range ${token} must be ascending."
        return 1
      fi
      if ((start < 1 || end > count)); then
        SHARE_SELECTION_ERROR="Range ${token} is out of range."
        return 1
      fi
      for ((current = start; current <= end; current++)); do
        append.share.selection.index "$((current - 1))"
      done
      continue
    fi
    SHARE_SELECTION_ERROR="Unsupported selection token: ${token}"
    return 1
  done
}

apply.share.selection.by.indexes() {
  local idx
  SELECTED_SHARES=()
  for idx in "${PARSED_SHARE_INDEXES[@]:-}"; do
    SELECTED_SHARES+=("${MOUNT_PATH[$idx]}")
  done
}

choose.shares.interactive() {
  local selection i

  printf '\nDetected container:\n' >&3
  printf '  hostname:      %s\n' "${CONTAINER_HOSTNAME}" >&3
  printf '  Debian:        %s\n' "${CONTAINER_OS_PRETTY}" >&3
  printf '  default route: %s\n' "${CONTAINER_DEFAULT_ROUTE:-unknown}" >&3
  printf '  IPv4:          %s\n\n' "$(printf '%s ' "${CONTAINER_IPV4[@]:-none}")" >&3
  printf 'Detected candidate shares:\n\n' >&3

  if ((${#MOUNT_PATH[@]} == 0)); then
    local continue_without_shares
    printf '  none\n\n' >&3
    continue_without_shares="$(prompt.tty "No mounted files were discovered. Continue with Samba base setup and no shares? (yes|no)" "no")"
    if is.true "${continue_without_shares}"; then
      ALLOW_EMPTY_SHARES="true"
      SELECTED_SHARES=()
      return 0
    fi
    log.error "Operator aborted because no share mountpoints were discovered."
    exit 1
  fi

  while true; do
    for i in "${!MOUNT_PATH[@]}"; do
      printf '  [ ] %d | %s | share=%s | fs=%s | read=%s | write=%s | xattr=%s\n' \
        "$((i + 1))" \
        "${MOUNT_PATH[$i]}" \
        "${MOUNT_SHARE_NAME[$i]}" \
        "${MOUNT_FSTYPE[$i]}" \
        "${MOUNT_READABLE[$i]}" \
        "${MOUNT_WRITABLE[$i]}" \
        "${MOUNT_XATTR[$i]}" >&3
    done
    printf '\nSelect shares: single `4`, range `1-5`, CSV `1,4,6`, mixed `1-4,7`, `ALL`, or `NONE`\n' >&3
    selection="$(prompt.tty "Selection" "NONE")"
    if parse.share.selection "${selection}"; then
      apply.share.selection.by.indexes
      if ((${#SELECTED_SHARES[@]} == 0)); then
        ALLOW_EMPTY_SHARES="true"
      fi
      return 0
    fi
    printf 'Invalid selection: %s\n\n' "${SHARE_SELECTION_ERROR:-unknown error}" >&3
  done
}

parse.share.paths.env() {
  local path found
  SELECTED_SHARES=()
  for path in ${PROXMOX_SAMBA_SHARE_PATHS}; do
    found=0
    local i
    for i in "${!MOUNT_PATH[@]}"; do
      if [[ "${MOUNT_PATH[$i]}" == "${path}" ]]; then
        SELECTED_SHARES+=("${path}")
        found=1
        break
      fi
    done
    if ((found == 0)); then
      log.error "Requested share path was not discovered: ${path}"
      exit 1
    fi
  done
}

normalize.allow.subnets() {
  read -r -a ALLOW_SUBNET_LIST <<< "${PROXMOX_SAMBA_ALLOW_SUBNETS}"
}

list.signature() {
  printf '%s\n' "$@" | awk 'NF {print}' | sort -u | tr '\n' ',' | sed 's/,$//'
}

normalize.allow.users() {
  local user
  if is.true "${PROXMOX_SAMBA_ALLOW_USERS_OVERRIDE}"; then
    PROXMOX_SAMBA_ALLOW_USERS_SELECTED=()
    for user in ${PROXMOX_SAMBA_ALLOW_USERS}; do
      [[ -n "${user}" ]] || continue
      PROXMOX_SAMBA_ALLOW_USERS_SELECTED+=("${user}")
    done
  else
    PROXMOX_SAMBA_ALLOW_USERS_SELECTED=()
    for user in ${PROXMOX_SAMBA_BASELINE_USERS}; do
      [[ -n "${user}" ]] || continue
      PROXMOX_SAMBA_ALLOW_USERS_SELECTED+=("${user}")
    done
  fi

  if ((${#PROXMOX_SAMBA_ALLOW_USERS_SELECTED[@]} == 0)); then
    read -r -a PROXMOX_SAMBA_ALLOW_USERS_SELECTED <<< "${PROXMOX_SAMBA_BASELINE_USERS}"
  fi

  PROXMOX_SAMBA_ALLOW_USERS_CLI=()
  if is.true "${PROXMOX_SAMBA_ALLOW_USERS_OVERRIDE}"; then
    PROXMOX_SAMBA_ALLOW_USERS_CLI=(${PROXMOX_SAMBA_ALLOW_USERS_SELECTED[@]})
  fi
}

assert.default.allow.users() {
  local baseline_signature
  local selected_signature

  if is.true "${PROXMOX_SAMBA_ALLOW_USERS_OVERRIDE}"; then
    return 0
  fi

  baseline_signature="$(list.signature ${PROXMOX_SAMBA_BASELINE_USERS})"
  selected_signature="$(list.signature "${PROXMOX_SAMBA_ALLOW_USERS_SELECTED[@]}")"

  if [[ "${selected_signature}" != "${baseline_signature}" ]]; then
    log.error "Unexpected Samba user set. Baseline: ${PROXMOX_SAMBA_BASELINE_USERS}. Selected: ${PROXMOX_SAMBA_ALLOW_USERS_SELECTED[*]}"
    log.error "Set PROXMOX_SAMBA_ALLOW_USERS explicitly to override."
    exit 1
  fi
}

validate.selection() {
  local path readable writable xattr
  ((${#MOUNT_PATH[@]} > 0)) || {
    if is.true "${ALLOW_EMPTY_SHARES}" || is.true "${PROXMOX_SAMBA_ALLOW_EMPTY_SHARES}"; then
      return 0
    fi
    log.error "No candidate share mountpoints were discovered."
    exit 1
  }
  ((${#SELECTED_SHARES[@]} > 0)) || {
    if is.true "${ALLOW_EMPTY_SHARES}" || is.true "${PROXMOX_SAMBA_ALLOW_EMPTY_SHARES}"; then
      return 0
    fi
    log.error "No Samba shares were selected."
    exit 1
  }
  if is.true "${PROXMOX_SAMBA_REQUIRE_XATTR}"; then
    local path idx
    for path in "${SELECTED_SHARES[@]}"; do
      for idx in "${!MOUNT_PATH[@]}"; do
        if [[ "${MOUNT_PATH[$idx]}" == "${path}" && "${MOUNT_XATTR[$idx]}" != "yes" ]]; then
          log.error "Selected share ${path} does not support xattrs and PROXMOX_SAMBA_REQUIRE_XATTR=1."
          exit 1
        fi
      done
    done
  fi
  for path in "${SELECTED_SHARES[@]}"; do
    readable="$(mount.readable.by.path "${path}")"
    writable="$(mount.writable.by.path "${path}")"
    xattr="$(mount.xattr.by.path "${path}")"
    if [[ "${readable}" != "yes" ]]; then
      log.warn "Selected share ${path} was probed as read=no. Guest browse may list it, but access may still fail until permissions are corrected."
    fi
    if [[ "${writable}" != "yes" ]]; then
      log.warn "Selected share ${path} was probed as write=no for the runner identity. Apply will verify the mapped Samba service identity before publishing it."
    fi
    if [[ "${xattr}" != "yes" ]]; then
      log.warn "Selected share ${path} was probed as xattr=no. macOS metadata compatibility may be reduced."
    fi
  done
}

write.selection.file() {
  mkdir -p "${FACTS_DIR}"
  cat > "${SAMBA_SELECTION_PATH}" <<EOF
---
proxmox_samba_operator_selection:
  confirmed: true
  source: "setup/lxc/samba.sh"
  mode: $(yaml.quote "${FEATURE_MODE}")
  container:
    hostname: $(yaml.quote "${CONTAINER_HOSTNAME}")
    ctid: $(yaml.scalar.or.null "${CONTAINER_CTID}")
    name: $(yaml.scalar.or.null "${CONTAINER_CTNAME}")
  network:
    allow_subnets:
$(for subnet in "${ALLOW_SUBNET_LIST[@]}"; do printf '      - %s\n' "$(yaml.quote "${subnet}")"; done)
    bind_interfaces_only: true
    interfaces:
      - "lo"
      - $(yaml.quote "${PROXMOX_SAMBA_DATA_INTERFACE}")
    data_interface: $(yaml.quote "${PROXMOX_SAMBA_DATA_INTERFACE}")
    egress_interface: $(yaml.quote "${PROXMOX_SAMBA_EGRESS_INTERFACE}")
    dns_servers:
$(for server in ${PROXMOX_SAMBA_DNS_SERVERS}; do printf '      - %s\n' "$(yaml.quote "${server}")"; done)
  auth:
    credential_mode: $(yaml.quote "${PROXMOX_SAMBA_CREDENTIAL_MODE}")
    username: $(yaml.quote "${PROXMOX_SAMBA_AUTH_USER}")
EOF
  if ((${#SELECTED_SHARES[@]} > 0)); then
    {
      printf '  shares:\n'
      for path in "${SELECTED_SHARES[@]}"; do
        printf '    - path: %s\n      name: %s\n      guest_ok: %s\n      writable: %s\n      readable: %s\n      xattr: %s\n' \
          "$(yaml.quote "${path}")" \
          "$(yaml.quote "$(selected.share.name.by.path "${path}")")" \
          "$(bool.yaml "${PROXMOX_SAMBA_GUEST_MODE}")" \
          "$(bool.yaml "$(mount.writable.by.path "${path}")")" \
          "$(bool.yaml "$(mount.readable.by.path "${path}")")" \
          "$(bool.yaml "$(mount.xattr.by.path "${path}")")"
      done
    } >> "${SAMBA_SELECTION_PATH}"
  else
    printf '  shares: []\n' >> "${SAMBA_SELECTION_PATH}"
  fi
}

write.runtime.facts() {
  cat > "${SAMBA_FACTS_PATH}" <<EOF
---
proxmox_samba_runtime:
  hostname: $(yaml.quote "${CONTAINER_HOSTNAME}")
  os_pretty_name: $(yaml.quote "${CONTAINER_OS_PRETTY}")
  default_route: $(yaml.scalar.or.null "${CONTAINER_DEFAULT_ROUTE}")
  mode: $(yaml.quote "${FEATURE_MODE}")
  allow_empty_shares: $(bool.yaml "${ALLOW_EMPTY_SHARES}")
  auth:
    credential_mode: $(yaml.quote "${PROXMOX_SAMBA_CREDENTIAL_MODE}")
    username: $(yaml.quote "${PROXMOX_SAMBA_AUTH_USER}")
EOF
  if ((${#SELECTED_SHARES[@]} > 0)); then
    {
      printf '  selected_shares:\n'
      for path in "${SELECTED_SHARES[@]}"; do
        printf '    - %s\n' "$(yaml.quote "${path}")"
      done
    } >> "${SAMBA_FACTS_PATH}"
  else
    printf '  selected_shares: []\n' >> "${SAMBA_FACTS_PATH}"
  fi
}

collect.operator.selection() {
  if is.true "${FEATURE_INTERACTIVE}" && open.tty; then
    choose.shares.interactive
  else
    if [[ -n "${PROXMOX_SAMBA_SHARE_PATHS}" ]]; then
      parse.share.paths.env
    elif ((${#MOUNT_PATH[@]} == 0)) && is.true "${PROXMOX_SAMBA_ALLOW_EMPTY_SHARES}"; then
      ALLOW_EMPTY_SHARES="true"
      SELECTED_SHARES=()
    else
      log.error "Interactive UI unavailable. Set PROXMOX_SAMBA_SHARE_PATHS for non-interactive mode."
      exit 1
    fi
  fi
  select.published.share.name
  select.network.roles
  normalize.allow.subnets
  validate.selection
  if ((${#SELECTED_SHARES[@]} > 0)); then
    log "Share selection summary: discovered=${#MOUNT_PATH[@]} selected=${#SELECTED_SHARES[@]} paths=$(printf '%s ' "${SELECTED_SHARES[@]}")"
  else
    log "Share selection summary: discovered=${#MOUNT_PATH[@]} selected=0 paths=none"
  fi
  write.selection.file
  write.runtime.facts
}

use.local.feature.files() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/../.." && pwd)"

  if [[ -r "${repo_root}/ansible/${SAMBA_PLAYBOOK_REL}" && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]]; then
    PLAYBOOK_ROOT="${repo_root}/ansible"
    PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
    GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
    SAMBA_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${SAMBA_PLAYBOOK_REL}"
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
  fetch.feature.file "${SAMBA_PLAYBOOK_URL}" "${SAMBA_PLAYBOOK_PATH}"
}

run.feature.playbook() {
  local playbook_path="$1"
  shift
  ansible.runtime.run -i localhost, -c local -e "@${GROUP_VARS_PATH}" "$@" "${playbook_path}"
}

write.samba.extra.vars.file() {
  mkdir -p "${TMP_DIR}"
  remove.samba.secret.file
  (umask 077; : > "${SAMBA_EXTRA_VARS_PATH}")
  cat > "${SAMBA_EXTRA_VARS_PATH}" <<EOF
---
proxmox_feature_defaults:
  samba:
    enabled: true
    mode: $(yaml.quote "${FEATURE_MODE}")
    require_container: $(bool.yaml "${FEATURE_REQUIRE_CONTAINER}")
    require_operator_selection: true

proxmox_feature_facts_dir: $(yaml.quote "${FACTS_DIR}")
proxmox_samba:
  facts_dir: $(yaml.quote "${FACTS_DIR}")
  container_facts_path: $(yaml.quote "${CONTAINER_FACTS_PATH}")
  runtime_facts_path: $(yaml.quote "${SAMBA_FACTS_PATH}")
  mounts_tsv_path: $(yaml.quote "${SAMBA_MOUNTS_TSV}")
  selection_path: $(yaml.quote "${SAMBA_SELECTION_PATH}")
  identity:
    workgroup: $(yaml.quote "${PROXMOX_SAMBA_WORKGROUP}")
    netbios_name: $(yaml.scalar.or.null "${PROXMOX_SAMBA_NETBIOS_NAME}")
  network:
    allow_subnets:
$(for subnet in "${ALLOW_SUBNET_LIST[@]}"; do printf '      - %s\n' "$(yaml.quote "${subnet}")"; done)
    interfaces:
      - "lo"
      - $(yaml.quote "${PROXMOX_SAMBA_DATA_INTERFACE}")
    data_interface: $(yaml.quote "${PROXMOX_SAMBA_DATA_INTERFACE}")
    egress_interface: $(yaml.quote "${PROXMOX_SAMBA_EGRESS_INTERFACE}")
    dns_servers:
$(for server in ${PROXMOX_SAMBA_DNS_SERVERS}; do printf '      - %s\n' "$(yaml.quote "${server}")"; done)
  ssh:
    enabled: $(bool.yaml "${PROXMOX_SAMBA_ENABLE_SSH}")
    allow_users:
$(for user in ${PROXMOX_SAMBA_BASELINE_USERS}; do printf '      - %s\n' "$(yaml.quote "${user}")"; done)
  optional_packages:
    avahi:
      enabled: $(bool.yaml "${PROXMOX_SAMBA_ENABLE_AVAHI}")
    ssh:
      enabled: $(bool.yaml "${PROXMOX_SAMBA_ENABLE_SSH}")
    ufw:
      enabled: $(bool.yaml "${PROXMOX_SAMBA_ENABLE_UFW}")
  firewall:
    enabled: $(bool.yaml "${PROXMOX_SAMBA_ENABLE_UFW}")
  samba:
    map_to_guest: $(yaml.quote "${PROXMOX_SAMBA_MAP_TO_GUEST}")
    guest_account: $(yaml.quote "${PROXMOX_SAMBA_GUEST_ACCOUNT}")
    force_user: $(yaml.scalar.or.null "${PROXMOX_SAMBA_FORCE_USER}")
    force_group: $(yaml.quote "${PROXMOX_SAMBA_FORCE_GROUP}")
    guest_mode: $(bool.yaml "${PROXMOX_SAMBA_GUEST_MODE}")
  auth:
    credential_mode: $(yaml.quote "${PROXMOX_SAMBA_CREDENTIAL_MODE}")
    username: $(yaml.quote "${PROXMOX_SAMBA_AUTH_USER}")
    password: $(yaml.quote "${PROXMOX_SAMBA_AUTH_PASSWORD}")
  shares:
$(if ((${#SELECTED_SHARES[@]} > 0)); then
  printf '    explicit:\n'
  for path in "${SELECTED_SHARES[@]}"; do
    printf '      - path: %s\n        name: %s\n        guest_ok: %s\n        writable: %s\n        readable: %s\n        xattr: %s\n' \
      "$(yaml.quote "${path}")" \
      "$(yaml.quote "$(selected.share.name.by.path "${path}")")" \
      "$(bool.yaml "${PROXMOX_SAMBA_GUEST_MODE}")" \
      "$(bool.yaml "$(mount.writable.by.path "${path}")")" \
      "$(bool.yaml "$(mount.readable.by.path "${path}")")" \
      "$(bool.yaml "$(mount.xattr.by.path "${path}")")"
  done
else
  printf '    explicit: []\n'
fi)
proxmox_samba_access_users_runner:
$(if ((${#PROXMOX_SAMBA_ALLOW_USERS_SELECTED[@]} > 0)); then
  for user in "${PROXMOX_SAMBA_ALLOW_USERS_SELECTED[@]}"; do
    printf '  - %s\n' "$(yaml.quote "${user}")"
  done
else
  for user in ${PROXMOX_SAMBA_BASELINE_USERS}; do
    printf '  - %s\n' "$(yaml.quote "${user}")"
  done
fi)
proxmox_samba_access_users_cli:
$(if is.true "${PROXMOX_SAMBA_ALLOW_USERS_OVERRIDE}"; then
  for user in "${PROXMOX_SAMBA_ALLOW_USERS_CLI[@]}"; do
    printf '  - %s\n' "$(yaml.quote "${user}")"
  done
else
  printf '  -\n'
fi)
proxmox_samba_access_users_override: $(bool.yaml "${PROXMOX_SAMBA_ALLOW_USERS_OVERRIDE}")
EOF
  chmod 0600 "${SAMBA_EXTRA_VARS_PATH}"
  log "Prepared Samba extra-vars: ${SAMBA_EXTRA_VARS_PATH}"
}

run.samba.feature() {
  detect.container.identity
  write.container.facts
  discover.mounts
  require.unique.share.names
  collect.operator.selection
  normalize.allow.users
  assert.default.allow.users
  write.samba.extra.vars.file
  log "Running Proxmox LXC Samba feature in mode=${FEATURE_MODE}..."
  run.feature.playbook "${SAMBA_PLAYBOOK_PATH}" -e "@${SAMBA_EXTRA_VARS_PATH}"
}

main() {
  if [[ "${EUID:-$(id -u)}" -ne 0 && -n "${PROXMOX_SAMBA_AUTH_PASSWORD}" ]]; then
    log.error 'For secret-safe elevation, run this command as root instead of passing a password through sudo re-exec.'
    exit 1
  fi
  ensure.root.or.sudo.reexec "${SAMBA_SUDO_REEXEC}" "${SAMBA_SELF_URL}" "$@"
  remove.samba.secret.file
  require.root
  require.apt
  require.valid.mode
  require.debian.container
  require.container.not.host
  ensure.container.ansible
  prepare.feature.files
  run.samba.feature
}

if ! is.true "${PROXMOX_SAMBA_SOURCE_ONLY:-0}"; then
  main "$@"
fi
