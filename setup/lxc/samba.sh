#!/usr/bin/env bash
## Manual Proxmox LXC Samba feature runner.
## Local usage:
##   ./setup/lxc/samba.sh [preflight|apply]
## Published usage:
##   wget -qO- https://devs-guide.github.io/proxmox/setup/lxc/samba.sh | bash

set -euo pipefail

log()       { printf '[setup.lxc.samba] %s\n' "$*" >&2; }
log.error() { printf '[setup.lxc.samba][error] %s\n' "$*" >&2; }

TMP_DIR="/tmp/pve-feature-samba"
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
PROXMOX_SAMBA_ENABLE_UFW="${PROXMOX_SAMBA_ENABLE_UFW:-0}"
PROXMOX_SAMBA_ENABLE_SSH="${PROXMOX_SAMBA_ENABLE_SSH:-0}"
PROXMOX_SAMBA_ENABLE_AVAHI="${PROXMOX_SAMBA_ENABLE_AVAHI:-1}"
PROXMOX_SAMBA_REQUIRE_XATTR="${PROXMOX_SAMBA_REQUIRE_XATTR:-0}"
PROXMOX_SAMBA_WORKGROUP="${PROXMOX_SAMBA_WORKGROUP:-WORKGROUP}"
PROXMOX_SAMBA_NETBIOS_NAME="${PROXMOX_SAMBA_NETBIOS_NAME:-}"
PROXMOX_SAMBA_FORCE_USER="${PROXMOX_SAMBA_FORCE_USER:-}"
PROXMOX_SAMBA_FORCE_GROUP="${PROXMOX_SAMBA_FORCE_GROUP:-storage}"
PROXMOX_SAMBA_GUEST_MODE="${PROXMOX_SAMBA_GUEST_MODE:-0}"
PROXMOX_SAMBA_PROFILE="${PROXMOX_SAMBA_PROFILE:-modern_mac}"
PROXMOX_SAMBA_ALLOW_SUBNETS="${PROXMOX_SAMBA_ALLOW_SUBNETS:-10.0.0.0/24 192.168.0.0/16}"
PROXMOX_SAMBA_SHARE_PATHS="${PROXMOX_SAMBA_SHARE_PATHS:-}"

declare -a MOUNT_PATH=()
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

CONTAINER_HOSTNAME=""
CONTAINER_DEFAULT_ROUTE=""
CONTAINER_OS_PRETTY=""
CONTAINER_CTID="${PROXMOX_CTID:-}"
CONTAINER_CTNAME="${PROXMOX_CTNAME:-}"
OPEN_TTY=0

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
  done < <(findmnt -R -n -o TARGET,SOURCE,FSTYPE,OPTIONS | awk '{target=$1; source=$2; fstype=$3; $1=$2=$3=""; sub(/^ +/,""); print target "|" source "|" fstype "|" $0}')

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

choose.shares.interactive() {
  local -a options=()
  local -a indexes=()
  local choice i selected

  printf '\nDetected container:\n' >&3
  printf '  hostname:      %s\n' "${CONTAINER_HOSTNAME}" >&3
  printf '  Debian:        %s\n' "${CONTAINER_OS_PRETTY}" >&3
  printf '  default route: %s\n' "${CONTAINER_DEFAULT_ROUTE:-unknown}" >&3
  printf '  IPv4:          %s\n\n' "$(printf '%s ' "${CONTAINER_IPV4[@]:-none}")" >&3
  printf 'Detected candidate shares:\n\n' >&3

  for i in "${!MOUNT_PATH[@]}"; do
    options+=("${MOUNT_PATH[$i]} | share=${MOUNT_SHARE_NAME[$i]} | fs=${MOUNT_FSTYPE[$i]} | read=${MOUNT_READABLE[$i]} | write=${MOUNT_WRITABLE[$i]} | xattr=${MOUNT_XATTR[$i]}")
    indexes+=("${i}")
  done
  options+=("all")
  options+=("abort")
  choice="$(menu.tty "Select share path:" "${options[@]}")"
  if ((choice == ${#options[@]})); then
    log.error "Operator aborted share selection."
    exit 1
  fi
  if ((choice == ${#options[@]} - 1)); then
    SELECTED_SHARES=("${MOUNT_PATH[@]}")
    return 0
  fi
  selected="${indexes[$((choice - 1))]}"
  SELECTED_SHARES=("${MOUNT_PATH[$selected]}")
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

validate.selection() {
  ((${#MOUNT_PATH[@]} > 0)) || {
    log.error "No candidate share mountpoints were discovered."
    exit 1
  }
  ((${#SELECTED_SHARES[@]} > 0)) || {
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
  shares:
$(for path in "${SELECTED_SHARES[@]}"; do printf '    - path: %s\n      guest_ok: false\n      writable: true\n' "$(yaml.quote "${path}")"; done)
EOF
}

write.runtime.facts() {
  cat > "${SAMBA_FACTS_PATH}" <<EOF
---
proxmox_samba_runtime:
  hostname: $(yaml.quote "${CONTAINER_HOSTNAME}")
  os_pretty_name: $(yaml.quote "${CONTAINER_OS_PRETTY}")
  default_route: $(yaml.scalar.or.null "${CONTAINER_DEFAULT_ROUTE}")
  mode: $(yaml.quote "${FEATURE_MODE}")
  selected_shares:
$(for path in "${SELECTED_SHARES[@]}"; do printf '    - %s\n' "$(yaml.quote "${path}")"; done)
EOF
}

collect.operator.selection() {
  if is.true "${FEATURE_INTERACTIVE}" && open.tty; then
    choose.shares.interactive
  else
    [[ -n "${PROXMOX_SAMBA_SHARE_PATHS}" ]] || {
      log.error "Interactive UI unavailable. Set PROXMOX_SAMBA_SHARE_PATHS for non-interactive mode."
      exit 1
    }
    parse.share.paths.env
  fi
  normalize.allow.subnets
  validate.selection
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
  "${ANSIBLE_VENV_BIN}" -i localhost, -c local -e "@${GROUP_VARS_PATH}" "$@" "${playbook_path}"
}

write.samba.extra.vars.file() {
  mkdir -p "${TMP_DIR}"
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
  ssh:
    enabled: $(bool.yaml "${PROXMOX_SAMBA_ENABLE_SSH}")
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
    force_user: $(yaml.scalar.or.null "${PROXMOX_SAMBA_FORCE_USER}")
    force_group: $(yaml.quote "${PROXMOX_SAMBA_FORCE_GROUP}")
    guest_mode: $(bool.yaml "${PROXMOX_SAMBA_GUEST_MODE}")
  shares:
    explicit:
$(for path in "${SELECTED_SHARES[@]}"; do printf '      - path: %s\n        guest_ok: false\n        writable: true\n' "$(yaml.quote "${path}")"; done)
EOF
  log "Prepared Samba extra-vars: ${SAMBA_EXTRA_VARS_PATH}"
}

run.samba.feature() {
  detect.container.identity
  write.container.facts
  discover.mounts
  require.unique.share.names
  collect.operator.selection
  write.samba.extra.vars.file
  log "Running Proxmox LXC Samba feature in mode=${FEATURE_MODE}..."
  run.feature.playbook "${SAMBA_PLAYBOOK_PATH}" -e "@${SAMBA_EXTRA_VARS_PATH}"
}

main() {
  require.root
  require.apt
  require.valid.mode
  require.debian.container
  require.container.not.host
  ensure.container.ansible
  prepare.feature.files
  run.samba.feature
}

main "$@"
