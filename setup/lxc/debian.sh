#!/usr/bin/env bash
## Manual Proxmox Debian LXC feature runner.
## Local usage:
##   ./setup/lxc/debian.sh [preflight|create|harden|apply]
## Published usage:
##   wget -qO- https://devs-guide.github.io/proxmox/setup/lxc/debian.sh | bash

set -euo pipefail

log()       { printf '[setup.lxc.debian] %s\n' "$*" >&2; }
log.error() { printf '[setup.lxc.debian][error] %s\n' "$*" >&2; }

TMP_DIR="/tmp/pve-feature-lxc-debian"
PAGES_BASE_URL="https://devs-guide.github.io/proxmox"
PLAYBOOK_ROOT="${TMP_DIR}/ansible"
PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
PLAYBOOK_DEBIAN_DIR="${PLAYBOOK_ROOT}/debian"
LOCAL_COMMON_HELPER="../../bootstrap/release.common.sh"
COMMON_HELPER_NAME="release.common.sh"
COMMON_HELPER_URL="${PAGES_BASE_URL}/${COMMON_HELPER_NAME}"
COMMON_HELPER_PATH="${TMP_DIR}/${COMMON_HELPER_NAME}"
GROUP_VARS_FILE="proxmox.yml"
GROUP_VARS_URL="${PAGES_BASE_URL}/ansible/group_vars/${GROUP_VARS_FILE}"
GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
NETBOOT_FILE="netboot.yml"
NETBOOT_URL="${PAGES_BASE_URL}/ansible/debian/${NETBOOT_FILE}"
NETBOOT_PATH="${PLAYBOOK_DEBIAN_DIR}/${NETBOOT_FILE}"
# Shared SSH defaults file consumed by ansible/proxmox/container/debian.base.yml:
# ansible/debian/ssh.yml
SSH_POLICY_FILE="ssh.yml"
SSH_POLICY_URL="${PAGES_BASE_URL}/ansible/debian/${SSH_POLICY_FILE}"
SSH_POLICY_PATH="${PLAYBOOK_DEBIAN_DIR}/${SSH_POLICY_FILE}"
DEBIAN_LXC_TEMPLATE_POLICY_VERSION="2026-05-02"
DEBIAN_LXC_TEMPLATE_BASE_URL="${PROXMOX_LXC_DEBIAN_TEMPLATE_BASE_URL:-https://download.proxmox.com/images/system}"
DEBIAN_LXC_TEMPLATE_MAJOR=(10 11 12 13)
DEBIAN_LXC_TEMPLATE_CODENAME=(buster bullseye bookworm trixie)
DEBIAN_LXC_TEMPLATE_NAME=(
  "debian-10-standard_10.7-1_amd64.tar.gz"
  "debian-11-standard_11.7-1_amd64.tar.zst"
  "debian-12-standard_12.12-1_amd64.tar.zst"
  "debian-13-standard_13.1-2_amd64.tar.zst"
)
DEBIAN_LXC_TEMPLATE_STATUS=(legacy oldstable stable-minus-one current)
FEATURE_PLAYBOOKS=(
  "proxmox/container/debian.lxc.yml"
  "proxmox/container/debian.base.yml"
)
DEBIAN_LXC_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[0]}"
DEBIAN_BASE_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[1]}"
DEBIAN_LXC_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${DEBIAN_LXC_PLAYBOOK_REL}"
DEBIAN_LXC_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${DEBIAN_LXC_PLAYBOOK_REL}"
DEBIAN_BASE_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${DEBIAN_BASE_PLAYBOOK_REL}"
DEBIAN_BASE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${DEBIAN_BASE_PLAYBOOK_REL}"
DEBIAN_LXC_EXTRA_VARS_PATH="${TMP_DIR}/lxc.debian.extra-vars.yml"
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
FACTS_DIR="${PROXMOX_LXC_DEBIAN_FACTS_DIR:-/etc/ansible/proxmox/facts}"
CONTAINERS_TSV_PATH="${PROXMOX_LXC_DEBIAN_CONTAINERS_TSV:-${FACTS_DIR}/lxc.debian.containers.tsv}"
TEMPLATES_TSV_PATH="${PROXMOX_LXC_DEBIAN_TEMPLATES_TSV:-${FACTS_DIR}/lxc.debian.templates.tsv}"
ISOS_TSV_PATH="${PROXMOX_LXC_DEBIAN_ISOS_TSV:-${FACTS_DIR}/lxc.debian.isos.tsv}"
SELECTION_PATH="${PROXMOX_LXC_DEBIAN_SELECTION_PATH:-${FACTS_DIR}/lxc.debian.selection.yml}"
RUNTIME_FACTS_PATH="${PROXMOX_LXC_DEBIAN_RUNTIME_FACTS_PATH:-${FACTS_DIR}/lxc.debian.yml}"
FEATURE_MODE="${1:-${PROXMOX_LXC_DEBIAN_MODE:-apply}}"
FEATURE_OPERATION="${PROXMOX_LXC_DEBIAN_OPERATION:-}"
FEATURE_INTERACTIVE="${PROXMOX_LXC_DEBIAN_INTERACTIVE:-1}"
FEATURE_ALLOW_CONTAINER="${PROXMOX_LXC_DEBIAN_ALLOW_CONTAINER:-0}"
FEATURE_ENABLE_UFW="${PROXMOX_LXC_DEBIAN_ENABLE_UFW:-0}"
DEFAULT_HOSTNAME="${PROXMOX_LXC_DEBIAN_HOSTNAME:-debian}"
DEFAULT_CTID="${PROXMOX_LXC_DEBIAN_CTID:-}"
DEFAULT_TEMPLATE="${PROXMOX_LXC_DEBIAN_TEMPLATE:-}"
DEFAULT_TEMPLATE_MAJOR="${PROXMOX_LXC_DEBIAN_TEMPLATE_MAJOR:-}"
DEFAULT_ROOTFS_STORAGE="${PROXMOX_LXC_DEBIAN_STORAGE:-local-lvm}"
DEFAULT_ROOTFS_SIZE_GB="${PROXMOX_LXC_DEBIAN_ROOTFS_GB:-10}"
DEFAULT_CORES="${PROXMOX_LXC_DEBIAN_CORES:-1}"
DEFAULT_MEMORY_MB="${PROXMOX_LXC_DEBIAN_MEMORY_MB:-512}"
DEFAULT_SWAP_MB="${PROXMOX_LXC_DEBIAN_SWAP_MB:-256}"
DEFAULT_BRIDGE="${PROXMOX_LXC_DEBIAN_BRIDGE:-vmbr1}"
DEFAULT_VLAN_TAG="${PROXMOX_LXC_DEBIAN_VLAN_TAG:-}"
DEFAULT_IPV4_MODE="${PROXMOX_LXC_DEBIAN_IPV4_MODE:-dhcp}"
DEFAULT_IPV4_CIDR="${PROXMOX_LXC_DEBIAN_IPV4_CIDR:-}"
DEFAULT_GATEWAY="${PROXMOX_LXC_DEBIAN_GATEWAY:-}"
DEFAULT_UNPRIVILEGED="${PROXMOX_LXC_DEBIAN_UNPRIVILEGED:-1}"
DEFAULT_NESTING="${PROXMOX_LXC_DEBIAN_NESTING:-0}"
DEFAULT_FUSE="${PROXMOX_LXC_DEBIAN_FUSE:-0}"
DEFAULT_HARDENING_PROFILE="${PROXMOX_LXC_DEBIAN_PROFILE:-minimal}"
DEFAULT_ACCESS_PROFILE="${PROXMOX_LXC_DEBIAN_ACCESS_PROFILE:-local_only}"
DEFAULT_ACCESS_USERS="${PROXMOX_LXC_DEBIAN_ACCESS_USERS:-agent proxmox root}"
DEFAULT_ALLOW_SUBNETS="${PROXMOX_LXC_DEBIAN_ALLOW_SUBNETS:-10.0.0.0/24 192.168.0.0/16}"
DEFAULT_EXPECTED_DNS="${PROXMOX_LXC_DEBIAN_EXPECTED_DNS:-10.0.0.1}"
DEFAULT_INTERNET_PROBE_IPV4="${PROXMOX_LXC_DEBIAN_INTERNET_PROBE_IPV4:-1.1.1.1}"
DEFAULT_MOUNTS="${PROXMOX_LXC_DEBIAN_MOUNTS:-}"

declare -a CT_IDS=()
declare -a CT_HOSTNAMES=()
declare -a CT_STATUS=()
declare -a CT_OSTYPE=()
declare -a CT_IPV4=()
declare -a TEMPLATE_LOCAL=()
declare -a TEMPLATE_REMOTE=()
declare -a TEMPLATE_REMOTE_RAW=()
declare -a TEMPLATE_POLICY_NAME=()
declare -a TEMPLATE_POLICY_LABEL=()
declare -a TEMPLATE_POLICY_STATUS=()
declare -a TEMPLATE_POLICY_AVAILABLE=()
declare -a STORAGE_NAME=()
declare -a STORAGE_TYPE=()
declare -a STORAGE_STATUS=()
declare -a BRIDGE_NAME=()
declare -a ISO_FILE=()
declare -a ISO_LABEL=()
declare -a ISO_PATH=()
declare -a NETBOOT_LABEL=()
declare -a NETBOOT_VERSION=()
declare -a NETBOOT_CODENAME=()
declare -a NETBOOT_ARCH=()
declare -a NETBOOT_URLS=()
declare -a MOUNT_HOST_PATH=()
declare -a MOUNT_SOURCE=()
declare -a MOUNT_FSTYPE=()
declare -a MOUNT_CONTAINER_PATH=()
declare -a SELECTED_ALLOW_SUBNETS=()
declare -a SELECTED_ACCESS_USERS=()
declare -a SELECTED_MOUNT_HOST_PATHS=()
declare -a SELECTED_MOUNT_CONTAINER_PATHS=()

OPEN_TTY=0
SELECTED_OPERATION=""
SELECTED_CTID=""
SELECTED_EXISTING_CTID=""
SELECTED_HOSTNAME=""
SELECTED_TEMPLATE_NAME=""
SELECTED_TEMPLATE_DOWNLOAD_IF_MISSING="false"
SELECTED_TEMPLATE_DOWNLOAD_METHOD="none"
SELECTED_TEMPLATE_URL=""
SELECTED_ROOTFS_STORAGE=""
SELECTED_ROOTFS_SIZE_GB=""
SELECTED_CORES=""
SELECTED_MEMORY_MB=""
SELECTED_SWAP_MB=""
SELECTED_BRIDGE=""
SELECTED_VLAN_TAG=""
SELECTED_IPV4_MODE=""
SELECTED_IPV4_CIDR=""
SELECTED_GATEWAY=""
SELECTED_UNPRIVILEGED="true"
SELECTED_NESTING="false"
SELECTED_FUSE="false"
SELECTED_HARDENING_PROFILE=""
SELECTED_ACCESS_PROFILE="local_only"
SELECTED_ENABLE_SSH="false"
SELECTED_ENABLE_UFW="false"

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
  # shellcheck source=/tmp/pve-feature-lxc-debian/release.common.sh
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

require.valid.mode() {
  case "${FEATURE_MODE}" in
    preflight|create|harden|apply) ;;
    *)
      log.error "Unsupported mode: ${FEATURE_MODE}"
      log.error "Use one of: preflight, create, harden, apply"
      exit 1
      ;;
  esac
}

require.proxmox.host() {
  if ! command -v pveversion >/dev/null 2>&1 || [[ ! -d /etc/pve ]]; then
    log.error "This Debian LXC feature must be run on a Proxmox host, not inside a container."
    exit 1
  fi

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    if systemd-detect-virt --quiet --container && ! is.true "${FEATURE_ALLOW_CONTAINER}"; then
      log.error "This Debian LXC feature must be run on a Proxmox host, not inside a container."
      exit 1
    fi
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

codename.for.version() {
  case "${1:-}" in
    10) printf 'Buster\n' ;;
    11) printf 'Bullseye\n' ;;
    12) printf 'Bookworm\n' ;;
    13) printf 'Trixie\n' ;;
    *) printf 'Debian\n' ;;
  esac
}

derive.iso.label() {
  local filename="$1"
  local version=""
  if [[ "${filename}" =~ debian-([0-9]+)\. ]]; then
    version="${BASH_REMATCH[1]}"
  elif [[ "${filename}" =~ debian-([0-9]+)- ]]; then
    version="${BASH_REMATCH[1]}"
  fi
  if [[ -n "${version}" ]]; then
    printf '%s:%s\n' "$(codename.for.version "${version}")" "${version}"
  else
    printf 'Debian:unknown\n'
  fi
}

sanitize.mount.label() {
  local label="$1"
  label="${label##*/}"
  label="${label,,}"
  label="$(printf '%s' "${label}" | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
  [[ -n "${label}" ]] || label="share"
  printf '%s\n' "${label}"
}

mount.container.path.for() {
  local host_path="$1"
  printf '/media/samba/%s\n' "$(sanitize.mount.label "${host_path}")"
}

path.is.excluded() {
  local path="$1"
  case "${path}" in
    /|/boot|/dev|/etc|/proc|/run|/sys|/tmp|/var|/var/lib/pve-cluster) return 0 ;;
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

normalize.allow.subnets() {
  read -r -a SELECTED_ALLOW_SUBNETS <<< "${DEFAULT_ALLOW_SUBNETS}"
}

normalize.access.users() {
  local user
  SELECTED_ACCESS_USERS=()
  for user in ${DEFAULT_ACCESS_USERS}; do
    [[ -n "${user}" ]] || continue
    SELECTED_ACCESS_USERS+=("${user}")
  done
  if ((${#SELECTED_ACCESS_USERS[@]} == 0)); then
    SELECTED_ACCESS_USERS=(agent proxmox root)
  fi
}

use.local.feature.files() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/../.." && pwd)"

  if [[ -r "${repo_root}/ansible/${DEBIAN_LXC_PLAYBOOK_REL}" \
        && -r "${repo_root}/ansible/${DEBIAN_BASE_PLAYBOOK_REL}" \
        && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" \
        && -r "${repo_root}/ansible/debian/${NETBOOT_FILE}" \
        && -r "${repo_root}/ansible/debian/${SSH_POLICY_FILE}" ]]; then
    PLAYBOOK_ROOT="${repo_root}/ansible"
    PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
    PLAYBOOK_DEBIAN_DIR="${PLAYBOOK_ROOT}/debian"
    GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
    NETBOOT_PATH="${PLAYBOOK_DEBIAN_DIR}/${NETBOOT_FILE}"
    SSH_POLICY_PATH="${PLAYBOOK_DEBIAN_DIR}/${SSH_POLICY_FILE}"
    DEBIAN_LXC_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${DEBIAN_LXC_PLAYBOOK_REL}"
    DEBIAN_BASE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${DEBIAN_BASE_PLAYBOOK_REL}"
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
  mkdir -p "${PLAYBOOK_GROUP_VARS_DIR}" "${PLAYBOOK_DEBIAN_DIR}"
  fetch.feature.file "${GROUP_VARS_URL}" "${GROUP_VARS_PATH}"
  fetch.feature.file "${NETBOOT_URL}" "${NETBOOT_PATH}"
  fetch.feature.file "${SSH_POLICY_URL}" "${SSH_POLICY_PATH}"
  fetch.feature.file "${DEBIAN_LXC_PLAYBOOK_URL}" "${DEBIAN_LXC_PLAYBOOK_PATH}"
  fetch.feature.file "${DEBIAN_BASE_PLAYBOOK_URL}" "${DEBIAN_BASE_PLAYBOOK_PATH}"
}

run.feature.playbook() {
  local playbook_path="$1"
  shift
  "${ANSIBLE_VENV_BIN}" -i localhost, -c local -e "@${GROUP_VARS_PATH}" "$@" "${playbook_path}"
}

load.netboot.catalog() {
  local current_label="" current_version="" current_codename="" current_arch="" current_url=""
  NETBOOT_LABEL=()
  NETBOOT_VERSION=()
  NETBOOT_CODENAME=()
  NETBOOT_ARCH=()
  NETBOOT_URLS=()

  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      *"- label:"*)
        if [[ -n "${current_label}" ]]; then
          NETBOOT_LABEL+=("${current_label}")
          NETBOOT_VERSION+=("${current_version}")
          NETBOOT_CODENAME+=("${current_codename}")
          NETBOOT_ARCH+=("${current_arch}")
          NETBOOT_URLS+=("${current_url}")
        fi
        current_label="$(printf '%s' "${line}" | sed 's/^[[:space:]]*-[[:space:]]*label:[[:space:]]*//; s/^"//; s/"$//')"
        current_version=""
        current_codename=""
        current_arch=""
        current_url=""
        ;;
      *"version:"*)
        current_version="$(printf '%s' "${line}" | sed 's/^[[:space:]]*version:[[:space:]]*//; s/^"//; s/"$//')"
        ;;
      *"codename:"*)
        current_codename="$(printf '%s' "${line}" | sed 's/^[[:space:]]*codename:[[:space:]]*//; s/^"//; s/"$//')"
        ;;
      *"arch:"*)
        current_arch="$(printf '%s' "${line}" | sed 's/^[[:space:]]*arch:[[:space:]]*//; s/^"//; s/"$//')"
        ;;
      *"netinst_url:"*)
        current_url="$(printf '%s' "${line}" | sed 's/^[[:space:]]*netinst_url:[[:space:]]*//; s/^"//; s/"$//')"
        ;;
    esac
  done < "${NETBOOT_PATH}"

  if [[ -n "${current_label}" ]]; then
    NETBOOT_LABEL+=("${current_label}")
    NETBOOT_VERSION+=("${current_version}")
    NETBOOT_CODENAME+=("${current_codename}")
    NETBOOT_ARCH+=("${current_arch}")
    NETBOOT_URLS+=("${current_url}")
  fi
}

discover.containers() {
  local ctid hostname status ostype ipv4
  CT_IDS=()
  CT_HOSTNAMES=()
  CT_STATUS=()
  CT_OSTYPE=()
  CT_IPV4=()

  while read -r ctid; do
    [[ -n "${ctid}" ]] || continue
    hostname="$(pct config "${ctid}" 2>/dev/null | awk '/^hostname:/ {print $2; exit}')"
    status="$(pct status "${ctid}" 2>/dev/null | awk '{print $2}')"
    ostype="$(pct config "${ctid}" 2>/dev/null | awk '/^ostype:/ {print $2; exit}')"
    ipv4="-"
    if [[ "${status}" == "running" ]]; then
      ipv4="$(pct exec "${ctid}" -- ip -o -4 addr show scope global 2>/dev/null | awk 'NR==1 {print $4}' | head -n1 || true)"
      ipv4="${ipv4:--}"
    fi
    CT_IDS+=("${ctid}")
    CT_HOSTNAMES+=("${hostname:-unknown}")
    CT_STATUS+=("${status:-unknown}")
    CT_OSTYPE+=("${ostype:-unknown}")
    CT_IPV4+=("${ipv4}")
  done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')

  mkdir -p "${FACTS_DIR}"
  {
    printf 'ctid\thostname\tstatus\tostype\tipv4\n'
    local i
    for i in "${!CT_IDS[@]}"; do
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "${CT_IDS[$i]}" "${CT_HOSTNAMES[$i]}" "${CT_STATUS[$i]}" "${CT_OSTYPE[$i]}" "${CT_IPV4[$i]}"
    done
  } > "${CONTAINERS_TSV_PATH}"
}

template.major.from.name() {
  local name="${1:-}"
  if [[ "${name}" =~ ^debian-([0-9]+)-standard_ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '\n'
}

template.codename.from.major() {
  case "${1:-}" in
    10) printf 'Buster\n' ;;
    11) printf 'Bullseye\n' ;;
    12) printf 'Bookworm\n' ;;
    13) printf 'Trixie\n' ;;
    *) printf 'Debian\n' ;;
  esac
}

template.policy.index.from.major() {
  local major="${1:-}" i
  for i in "${!DEBIAN_LXC_TEMPLATE_MAJOR[@]}"; do
    if [[ "${DEBIAN_LXC_TEMPLATE_MAJOR[$i]}" == "${major}" ]]; then
      printf '%s\n' "${i}"
      return 0
    fi
  done
  return 1
}

template.policy.name.from.major() {
  local major="${1:-}" idx
  if ! idx="$(template.policy.index.from.major "${major}")"; then
    return 1
  fi
  printf '%s\n' "${DEBIAN_LXC_TEMPLATE_NAME[$idx]}"
}

template.policy.index.from.name() {
  local name="${1:-}" i
  for i in "${!DEBIAN_LXC_TEMPLATE_NAME[@]}"; do
    if [[ "${DEBIAN_LXC_TEMPLATE_NAME[$i]}" == "${name}" ]]; then
      printf '%s\n' "${i}"
      return 0
    fi
  done
  return 1
}

template.policy.url.from.name() {
  local name="${1:-}"
  [[ -n "${name}" ]] || return 1
  printf '%s/%s\n' "${DEBIAN_LXC_TEMPLATE_BASE_URL%/}" "${name}"
}

template.remote.advertises.name() {
  local needle="${1:-}" item
  for item in "${TEMPLATE_REMOTE_RAW[@]:-}"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

build.template.policy.view() {
  local i major codename label name status available
  TEMPLATE_REMOTE=()
  TEMPLATE_POLICY_NAME=()
  TEMPLATE_POLICY_LABEL=()
  TEMPLATE_POLICY_STATUS=()
  TEMPLATE_POLICY_AVAILABLE=()

  for i in "${!DEBIAN_LXC_TEMPLATE_MAJOR[@]}"; do
    major="${DEBIAN_LXC_TEMPLATE_MAJOR[$i]}"
    codename="$(template.codename.from.major "${major}")"
    label="${codename}:${major}"
    name="${DEBIAN_LXC_TEMPLATE_NAME[$i]}"
    status="${DEBIAN_LXC_TEMPLATE_STATUS[$i]}"
    available="false"
    if template.remote.advertises.name "${name}"; then
      available="true"
      TEMPLATE_REMOTE+=("${name}")
    fi
    TEMPLATE_POLICY_NAME+=("${name}")
    TEMPLATE_POLICY_LABEL+=("${label}")
    TEMPLATE_POLICY_STATUS+=("${status}")
    TEMPLATE_POLICY_AVAILABLE+=("${available}")
  done
}

discover.local.templates() {
  TEMPLATE_LOCAL=()
  if [[ -d /var/lib/vz/template/cache ]]; then
    while IFS= read -r file; do
      [[ -n "${file}" ]] || continue
      TEMPLATE_LOCAL+=("${file}")
    done < <(find /var/lib/vz/template/cache -maxdepth 1 -type f -print 2>/dev/null | xargs -n1 basename 2>/dev/null | grep -i '^debian' || true)
  fi

  mkdir -p "${FACTS_DIR}"
  {
    printf 'template_name\tsource\n'
    local entry
    for entry in "${TEMPLATE_LOCAL[@]}"; do
      printf '%s\tlocal-cache\n' "${entry}"
    done
  } > "${TEMPLATES_TSV_PATH}"
}

discover.remote.templates() {
  TEMPLATE_REMOTE_RAW=()

  if ! pveam update >/dev/null 2>&1; then
    log "Warning: pveam update failed; continuing with current available catalog."
  fi

  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    TEMPLATE_REMOTE_RAW+=("${name}")
  done < <(pveam available --section system 2>/dev/null | awk 'NR>1 {print $2}' | grep -E '^debian-[0-9]+-standard_.*amd64\.tar\.(zst|gz)$' || true)

  build.template.policy.view
}

show.raw.remote.templates() {
  local i
  if ((OPEN_TTY == 0)); then
    return 0
  fi

  printf '\nRaw pveam Debian template list (policy version: %s):\n' "${DEBIAN_LXC_TEMPLATE_POLICY_VERSION}" >&3
  if ((${#TEMPLATE_REMOTE_RAW[@]} == 0)); then
    printf '  (no Debian templates currently advertised by pveam)\n' >&3
  else
    for i in "${!TEMPLATE_REMOTE_RAW[@]}"; do
      printf '  %s\n' "${TEMPLATE_REMOTE_RAW[$i]}" >&3
    done
  fi
  printf '\n' >&3
}

discover.storage() {
  STORAGE_NAME=()
  STORAGE_TYPE=()
  STORAGE_STATUS=()
  while read -r name type active _rest; do
    [[ -n "${name}" ]] || continue
    [[ "${name}" == "Name" ]] && continue
    STORAGE_NAME+=("${name}")
    STORAGE_TYPE+=("${type:-unknown}")
    STORAGE_STATUS+=("${active:-unknown}")
  done < <(pvesm status -content rootdir 2>/dev/null || pvesm status 2>/dev/null || true)
}

discover.bridges() {
  BRIDGE_NAME=()
  while IFS= read -r bridge; do
    [[ -n "${bridge}" ]] || continue
    BRIDGE_NAME+=("${bridge}")
  done < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' || true)
}

discover.isos() {
  local path file label
  ISO_FILE=()
  ISO_LABEL=()
  ISO_PATH=()
  if [[ -d /var/lib/vz/template/iso ]]; then
    while IFS= read -r path; do
      [[ -n "${path}" ]] || continue
      file="$(basename "${path}")"
      [[ "${file}" == *.tmp_dwnl.* ]] && continue
      printf '%s' "${file}" | grep -Eiq '^debian-.*\.(iso|img)$' || continue
      label="$(derive.iso.label "${file}")"
      ISO_FILE+=("${file}")
      ISO_LABEL+=("${label}")
      ISO_PATH+=("${path}")
    done < <(find /var/lib/vz/template/iso -maxdepth 1 -type f -print 2>/dev/null | sort)
  fi

  mkdir -p "${FACTS_DIR}"
  {
    printf 'label\tfile\tpath\n'
    local i
    for i in "${!ISO_FILE[@]}"; do
      printf '%s\t%s\t%s\n' "${ISO_LABEL[$i]}" "${ISO_FILE[$i]}" "${ISO_PATH[$i]}"
    done
  } > "${ISOS_TSV_PATH}"
}

discover.mountpoints() {
  local path source fstype options container_path
  MOUNT_HOST_PATH=()
  MOUNT_SOURCE=()
  MOUNT_FSTYPE=()
  MOUNT_CONTAINER_PATH=()

  while IFS='|' read -r path source fstype options; do
    [[ -n "${path}" ]] || continue
    path.is.excluded "${path}" && continue
    path.is.included_root "${path}" || continue
    fstype.is.excluded "${fstype}" && continue
    [[ -d "${path}" ]] || continue
    container_path="$(mount.container.path.for "${path}")"
    MOUNT_HOST_PATH+=("${path}")
    MOUNT_SOURCE+=("${source:-unknown}")
    MOUNT_FSTYPE+=("${fstype:-unknown}")
    MOUNT_CONTAINER_PATH+=("${container_path}")
  done < <(findmnt -R -n -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | awk '{target=$1; source=$2; fstype=$3; $1=$2=$3=""; sub(/^ +/,""); print target "|" source "|" fstype "|" $0}')
}

append.mount.selection.index() {
  local candidate="$1"
  local existing
  for existing in "${PARSED_MOUNT_INDEXES[@]:-}"; do
    [[ "${existing}" == "${candidate}" ]] && return 0
  done
  PARSED_MOUNT_INDEXES+=("${candidate}")
}

parse.mountpoint.selection() {
  local raw="${1:-}"
  local token value start end current
  local count="${#MOUNT_HOST_PATH[@]}"

  PARSED_MOUNT_INDEXES=()
  MOUNT_SELECTION_ERROR=""

  raw="$(printf '%s' "${raw}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [[ -z "${raw}" || "${raw^^}" == "NONE" ]]; then
    return 0
  fi

  if [[ "${raw^^}" == "ALL" ]]; then
    for current in "${!MOUNT_HOST_PATH[@]}"; do
      PARSED_MOUNT_INDEXES+=("${current}")
    done
    return 0
  fi

  raw="${raw//[[:space:]]/}"
  IFS=',' read -r -a MOUNT_SELECTION_TOKENS <<< "${raw}"
  for token in "${MOUNT_SELECTION_TOKENS[@]}"; do
    if [[ -z "${token}" ]]; then
      MOUNT_SELECTION_ERROR="Empty selection token is not valid."
      return 1
    fi
    if [[ "${token}" =~ ^[0-9]+$ ]]; then
      value="${token}"
      if ((value < 1 || value > count)); then
        MOUNT_SELECTION_ERROR="Selection ${value} is out of range."
        return 1
      fi
      append.mount.selection.index "$((value - 1))"
      continue
    fi
    if [[ "${token}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if ((start > end)); then
        MOUNT_SELECTION_ERROR="Range ${token} must be ascending."
        return 1
      fi
      if ((start < 1 || end > count)); then
        MOUNT_SELECTION_ERROR="Range ${token} is out of range."
        return 1
      fi
      for ((current = start; current <= end; current++)); do
        append.mount.selection.index "$((current - 1))"
      done
      continue
    fi
    MOUNT_SELECTION_ERROR="Unsupported selection token: ${token}"
    return 1
  done
}

apply.mount.selection.by.indexes() {
  local idx
  SELECTED_MOUNT_HOST_PATHS=()
  SELECTED_MOUNT_CONTAINER_PATHS=()
  for idx in "${PARSED_MOUNT_INDEXES[@]:-}"; do
    SELECTED_MOUNT_HOST_PATHS+=("${MOUNT_HOST_PATH[$idx]}")
    SELECTED_MOUNT_CONTAINER_PATHS+=("${MOUNT_CONTAINER_PATH[$idx]}")
  done
}

apply.mount.selection.defaults() {
  local host_path

  SELECTED_MOUNT_HOST_PATHS=()
  SELECTED_MOUNT_CONTAINER_PATHS=()

  if [[ -z "${DEFAULT_MOUNTS}" ]]; then
    return 0
  fi

  case "${DEFAULT_MOUNTS^^}" in
    NONE) return 0 ;;
    ALL)
      SELECTED_MOUNT_HOST_PATHS=("${MOUNT_HOST_PATH[@]}")
      SELECTED_MOUNT_CONTAINER_PATHS=("${MOUNT_CONTAINER_PATH[@]}")
      return 0
      ;;
  esac

  for host_path in ${DEFAULT_MOUNTS}; do
    [[ -n "${host_path}" ]] || continue
    SELECTED_MOUNT_HOST_PATHS+=("${host_path}")
    SELECTED_MOUNT_CONTAINER_PATHS+=("$(mount.container.path.for "${host_path}")")
  done
}

next.available.ctid() {
  local max_id=100
  local id
  for id in "${CT_IDS[@]:-}"; do
    [[ "${id}" =~ ^[0-9]+$ ]] || continue
    if ((id >= max_id)); then
      max_id=$((id + 1))
    fi
  done
  printf '%s\n' "${max_id}"
}

print.discovery.summary() {
  log "Detected Proxmox LXC inventory:"
  if ((${#CT_IDS[@]} == 0)); then
    printf '  (no existing containers)\n' >&2
  else
    local i
    for i in "${!CT_IDS[@]}"; do
      printf '  ctid=%s | host=%s | status=%s | ostype=%s | ip=%s\n' \
        "${CT_IDS[$i]}" "${CT_HOSTNAMES[$i]}" "${CT_STATUS[$i]}" "${CT_OSTYPE[$i]}" "${CT_IPV4[$i]}" >&2
    done
  fi

  printf '\n' >&2
  log "Detected local Debian LXC templates:"
  if ((${#TEMPLATE_LOCAL[@]} == 0)); then
    printf '  (no local Debian LXC templates)\n' >&2
  else
    printf '  %s\n' "$(printf '%s ' "${TEMPLATE_LOCAL[@]}")" >&2
  fi

  printf '\n' >&2
  log "Detected local Debian ISOs:"
  if ((${#ISO_FILE[@]} == 0)); then
    printf '  (no local Debian ISOs)\n' >&2
  else
    local i
    for i in "${!ISO_FILE[@]}"; do
      printf '  %s | %s\n' "${ISO_LABEL[$i]}" "${ISO_FILE[$i]}" >&2
    done
  fi

  printf '\n' >&2
  log "Configured Debian web references from ansible/debian/netboot.yml:"
  local i
  if ((${#NETBOOT_LABEL[@]} == 0)); then
    printf '  (no Debian web references parsed)\n' >&2
  else
    for i in "${!NETBOOT_LABEL[@]}"; do
      printf '  %s | %s\n' "${NETBOOT_LABEL[$i]}" "${NETBOOT_URLS[$i]}" >&2
    done
  fi
}

show.iso.context() {
  if ((OPEN_TTY == 0)); then
    return 0
  fi

  printf '\nDebian ISO inventory (informational only; LXC uses templates, not ISOs):\n' >&3
  if ((${#ISO_FILE[@]} > 0)); then
    local i
    for i in "${!ISO_FILE[@]}"; do
      printf '  %s | %s | %s\n' "${ISO_LABEL[$i]}" "${ISO_FILE[$i]}" "${ISO_PATH[$i]}" >&3
    done
  else
    printf '  No local Debian ISOs found.\n' >&3
  fi

  printf '  Web-based Debian netinst references from ansible/debian/netboot.yml:\n' >&3
  if ((${#NETBOOT_LABEL[@]} == 0)); then
    printf '  (no Debian web references parsed)\n' >&3
  else
    local i
    for i in "${!NETBOOT_LABEL[@]}"; do
      printf '  %s | %s\n' "${NETBOOT_LABEL[$i]}" "${NETBOOT_URLS[$i]}" >&3
    done
  fi
  printf '\n' >&3
}

select.operation.interactive() {
  local choice
  case "${FEATURE_MODE}" in
    create)
      SELECTED_OPERATION="create"
      return 0
      ;;
    harden)
      SELECTED_OPERATION="use_existing"
      return 0
      ;;
  esac

  choice="$(menu.tty "Select Debian LXC operation:" \
    "preflight only" \
    "use existing Debian LXC" \
    "create new Debian LXC" \
    "abort")"
  case "${choice}" in
    1) FEATURE_MODE="preflight"; SELECTED_OPERATION="preflight" ;;
    2) SELECTED_OPERATION="use_existing" ;;
    3) SELECTED_OPERATION="create" ;;
    *) log.error "Operator aborted."; exit 1 ;;
  esac
}

select.existing.container() {
  local -a options=()
  local choice idx
  ((${#CT_IDS[@]} > 0)) || {
    log.error "No existing LXC containers were discovered."
    exit 1
  }
  for idx in "${!CT_IDS[@]}"; do
    options+=("${CT_IDS[$idx]} | ${CT_HOSTNAMES[$idx]} | status=${CT_STATUS[$idx]} | ostype=${CT_OSTYPE[$idx]} | ip=${CT_IPV4[$idx]}")
  done
  options+=("abort")
  choice="$(menu.tty "Select existing LXC:" "${options[@]}")"
  if ((choice == ${#options[@]})); then
    log.error "Operator aborted container selection."
    exit 1
  fi
  idx=$((choice - 1))
  SELECTED_CTID="${CT_IDS[$idx]}"
  SELECTED_EXISTING_CTID="${CT_IDS[$idx]}"
  SELECTED_HOSTNAME="${CT_HOSTNAMES[$idx]}"
}

select.template.interactive() {
  local -a options=()
  local choice idx policy_name policy_available policy_status policy_desc

  if [[ -n "${DEFAULT_TEMPLATE}" ]]; then
    SELECTED_TEMPLATE_NAME="${DEFAULT_TEMPLATE}"
    if printf '%s\n' "${TEMPLATE_LOCAL[@]:-}" | grep -Fxq "${DEFAULT_TEMPLATE}"; then
      SELECTED_TEMPLATE_DOWNLOAD_IF_MISSING="false"
      SELECTED_TEMPLATE_DOWNLOAD_METHOD="local"
      SELECTED_TEMPLATE_URL=""
      return 0
    fi

    discover.remote.templates
    if template.remote.advertises.name "${DEFAULT_TEMPLATE}"; then
      SELECTED_TEMPLATE_DOWNLOAD_IF_MISSING="true"
      SELECTED_TEMPLATE_DOWNLOAD_METHOD="pveam"
      SELECTED_TEMPLATE_URL=""
      return 0
    fi

    if template.policy.index.from.name "${DEFAULT_TEMPLATE}" >/dev/null 2>&1; then
      SELECTED_TEMPLATE_DOWNLOAD_IF_MISSING="true"
      SELECTED_TEMPLATE_DOWNLOAD_METHOD="url"
      SELECTED_TEMPLATE_URL="$(template.policy.url.from.name "${DEFAULT_TEMPLATE}")"
      return 0
    fi

    log.error "Template ${DEFAULT_TEMPLATE} is not in local cache, is not currently advertised by pveam, and is not in the Debian LXC policy fallback list."
    exit 1
  fi

  if [[ -n "${DEFAULT_TEMPLATE_MAJOR}" ]]; then
    if ! SELECTED_TEMPLATE_NAME="$(template.policy.name.from.major "${DEFAULT_TEMPLATE_MAJOR}")"; then
      log.error "Unsupported PROXMOX_LXC_DEBIAN_TEMPLATE_MAJOR=${DEFAULT_TEMPLATE_MAJOR}. Supported: 10 11 12 13."
      exit 1
    fi

    if printf '%s\n' "${TEMPLATE_LOCAL[@]:-}" | grep -Fxq "${SELECTED_TEMPLATE_NAME}"; then
      SELECTED_TEMPLATE_DOWNLOAD_IF_MISSING="false"
      SELECTED_TEMPLATE_DOWNLOAD_METHOD="local"
      SELECTED_TEMPLATE_URL=""
      return 0
    fi

    discover.remote.templates
    if template.remote.advertises.name "${SELECTED_TEMPLATE_NAME}"; then
      SELECTED_TEMPLATE_DOWNLOAD_IF_MISSING="true"
      SELECTED_TEMPLATE_DOWNLOAD_METHOD="pveam"
      SELECTED_TEMPLATE_URL=""
      return 0
    fi

    SELECTED_TEMPLATE_DOWNLOAD_IF_MISSING="true"
    SELECTED_TEMPLATE_DOWNLOAD_METHOD="url"
    SELECTED_TEMPLATE_URL="$(template.policy.url.from.name "${SELECTED_TEMPLATE_NAME}")"
    return 0
  fi

  if ((${#TEMPLATE_LOCAL[@]} > 0)); then
    for idx in "${!TEMPLATE_LOCAL[@]}"; do
      options+=("${TEMPLATE_LOCAL[$idx]} | local")
    done
    options+=("show Debian ISO + web reference context")
    options+=("abort")
    choice="$(menu.tty "Select local Debian LXC template:" "${options[@]}")"
    if ((choice == ${#options[@]})); then
      log.error "Operator aborted template selection."
      exit 1
    fi
    if ((choice == ${#options[@]} - 1)); then
      show.iso.context
      options=()
      for idx in "${!TEMPLATE_LOCAL[@]}"; do
        options+=("${TEMPLATE_LOCAL[$idx]} | local")
      done
      options+=("abort")
      choice="$(menu.tty "Select local Debian LXC template:" "${options[@]}")"
      if ((choice == ${#options[@]})); then
        log.error "Operator aborted template selection."
        exit 1
      fi
    fi
    idx=$((choice - 1))
    SELECTED_TEMPLATE_NAME="${TEMPLATE_LOCAL[$idx]}"
    SELECTED_TEMPLATE_DOWNLOAD_IF_MISSING="false"
    SELECTED_TEMPLATE_DOWNLOAD_METHOD="local"
    SELECTED_TEMPLATE_URL=""
    return 0
  fi

  show.iso.context
  discover.remote.templates
  ((${#TEMPLATE_POLICY_NAME[@]} > 0)) || {
    log.error "No Debian template policy entries are configured."
    exit 1
  }

  while true; do
    options=()
    for idx in "${!TEMPLATE_POLICY_NAME[@]}"; do
      policy_name="${TEMPLATE_POLICY_NAME[$idx]}"
      policy_available="${TEMPLATE_POLICY_AVAILABLE[$idx]}"
      policy_status="${TEMPLATE_POLICY_STATUS[$idx]}"
      if [[ "${policy_available}" == "true" ]]; then
        policy_desc="remote download via pveam"
        if [[ "${policy_status}" == "legacy" ]]; then
          policy_desc="remote download via pveam / legacy"
        fi
      else
        policy_desc="official URL fallback (not currently advertised by pveam)"
      fi
      options+=("${TEMPLATE_POLICY_LABEL[$idx]} | ${policy_name} | ${policy_desc}")
    done
    options+=("show raw pveam Debian template list")
    options+=("abort")

    choice="$(menu.tty "Select Debian LXC template to download:" "${options[@]}")"
    if ((choice == ${#options[@]})); then
      log.error "Operator aborted remote template selection."
      exit 1
    fi
    if ((choice == ${#options[@]} - 1)); then
      show.raw.remote.templates
      continue
    fi

    idx=$((choice - 1))
    SELECTED_TEMPLATE_NAME="${TEMPLATE_POLICY_NAME[$idx]}"
    SELECTED_TEMPLATE_DOWNLOAD_IF_MISSING="true"
    if [[ "${TEMPLATE_POLICY_AVAILABLE[$idx]}" == "true" ]]; then
      SELECTED_TEMPLATE_DOWNLOAD_METHOD="pveam"
      SELECTED_TEMPLATE_URL=""
    else
      SELECTED_TEMPLATE_DOWNLOAD_METHOD="url"
      SELECTED_TEMPLATE_URL="$(template.policy.url.from.name "${SELECTED_TEMPLATE_NAME}")"
    fi
    return 0
  done
}

select.storage.interactive() {
  local -a options=()
  local choice idx default_index=0
  ((${#STORAGE_NAME[@]} > 0)) || {
    log.error "No Proxmox storage targets were discovered."
    exit 1
  }
  for idx in "${!STORAGE_NAME[@]}"; do
    options+=("${STORAGE_NAME[$idx]} | type=${STORAGE_TYPE[$idx]} | active=${STORAGE_STATUS[$idx]}")
    if [[ "${STORAGE_NAME[$idx]}" == "${DEFAULT_ROOTFS_STORAGE}" ]]; then
      default_index="${idx}"
    fi
  done
  options+=("abort")
  choice="$(menu.tty "Select rootfs storage:" "${options[@]}")"
  if ((choice == ${#options[@]})); then
    log.error "Operator aborted storage selection."
    exit 1
  fi
  idx=$((choice - 1))
  SELECTED_ROOTFS_STORAGE="${STORAGE_NAME[$idx]}"
}

select.bridge.interactive() {
  local -a options=()
  local choice idx
  ((${#BRIDGE_NAME[@]} > 0)) || {
    log.error "No bridge devices were discovered on the Proxmox host."
    exit 1
  }
  for idx in "${!BRIDGE_NAME[@]}"; do
    options+=("${BRIDGE_NAME[$idx]}")
  done
  options+=("abort")
  choice="$(menu.tty "Select bridge:" "${options[@]}")"
  if ((choice == ${#options[@]})); then
    log.error "Operator aborted bridge selection."
    exit 1
  fi
  idx=$((choice - 1))
  SELECTED_BRIDGE="${BRIDGE_NAME[$idx]}"
}

select.mountpoints.interactive() {
  local idx selection

  if [[ -n "${DEFAULT_MOUNTS}" ]]; then
    apply.mount.selection.defaults
    return 0
  fi

  ((${#MOUNT_HOST_PATH[@]} > 0)) || return 0

  while true; do
    printf 'Selectable host mountpoints for container passthrough:\n\n' >&3
    for idx in "${!MOUNT_HOST_PATH[@]}"; do
      printf '  [ ] %d | %s | fs=%s | source=%s | ct=%s\n' \
        "$((idx + 1))" \
        "${MOUNT_HOST_PATH[$idx]}" \
        "${MOUNT_FSTYPE[$idx]}" \
        "${MOUNT_SOURCE[$idx]}" \
        "${MOUNT_CONTAINER_PATH[$idx]}" >&3
    done
    printf '\nSelect mountpoints: single `4`, range `2-4`, CSV `1,3,4`, `ALL`, or `NONE`\n' >&3
    selection="$(prompt.tty "Selection" "NONE")"
    if parse.mountpoint.selection "${selection}"; then
      apply.mount.selection.by.indexes
      return 0
    fi
    printf 'Invalid selection: %s\n\n' "${MOUNT_SELECTION_ERROR:-unknown error}" >&3
  done
}

collect.create.settings() {
  SELECTED_CTID="${DEFAULT_CTID:-$(next.available.ctid)}"
  SELECTED_CTID="$(prompt.tty "Enter CTID" "${SELECTED_CTID}")"
  SELECTED_HOSTNAME="$(prompt.tty "Enter container hostname" "${DEFAULT_HOSTNAME}")"
  select.template.interactive
  show.iso.context
  select.storage.interactive
  SELECTED_ROOTFS_SIZE_GB="$(prompt.tty "Enter rootfs size in GB" "${DEFAULT_ROOTFS_SIZE_GB}")"
  SELECTED_CORES="$(prompt.tty "Enter CPU cores" "${DEFAULT_CORES}")"
  SELECTED_MEMORY_MB="$(prompt.tty "Enter memory in MB" "${DEFAULT_MEMORY_MB}")"
  SELECTED_SWAP_MB="$(prompt.tty "Enter swap in MB" "${DEFAULT_SWAP_MB}")"
  select.bridge.interactive
  SELECTED_VLAN_TAG="$(prompt.tty "Enter VLAN tag (blank for none)" "${DEFAULT_VLAN_TAG}")"
  SELECTED_IPV4_MODE="$(prompt.tty "Select IPv4 mode (dhcp|static)" "${DEFAULT_IPV4_MODE}")"
  if [[ "${SELECTED_IPV4_MODE}" == "static" ]]; then
    SELECTED_IPV4_CIDR="$(prompt.tty "Enter IPv4 CIDR" "${DEFAULT_IPV4_CIDR}")"
    SELECTED_GATEWAY="$(prompt.tty "Enter gateway" "${DEFAULT_GATEWAY}")"
  else
    SELECTED_IPV4_CIDR=""
    SELECTED_GATEWAY=""
  fi
  if is.true "$(prompt.tty "Create as unprivileged container? (yes|no)" "$(is.true "${DEFAULT_UNPRIVILEGED}" && printf yes || printf no)")"; then
    SELECTED_UNPRIVILEGED="true"
  else
    SELECTED_UNPRIVILEGED="false"
  fi
  if is.true "$(prompt.tty "Enable nesting? (yes|no)" "$(is.true "${DEFAULT_NESTING}" && printf yes || printf no)")"; then
    SELECTED_NESTING="true"
  else
    SELECTED_NESTING="false"
  fi
  if is.true "$(prompt.tty "Enable fuse? (yes|no)" "$(is.true "${DEFAULT_FUSE}" && printf yes || printf no)")"; then
    SELECTED_FUSE="true"
  else
    SELECTED_FUSE="false"
  fi
  select.mountpoints.interactive
}

normalize.hardening.profile() {
  case "${1:-}" in
    ultra_lean) printf 'minimal\n' ;;
    ultra_lean_monitoring|ultra_lean_tools) printf 'tools\n' ;;
    minimal|tools) printf '%s\n' "${1}" ;;
    *) printf '%s\n' "${1:-minimal}" ;;
  esac
}

normalize.access.profile() {
  case "${1:-}" in
    test_access|test|ssh|remote) printf 'test_access\n' ;;
    *) printf 'local_only\n' ;;
  esac
}

collect.hardening.selection() {
  local choice enable_ufw_choice access_choice
  choice="$(menu.tty "Select hardening profile:" \
    "minimal: debian only" \
    "tools + debian")"
  case "${choice}" in
    1) SELECTED_HARDENING_PROFILE="minimal" ;;
    2) SELECTED_HARDENING_PROFILE="tools" ;;
  esac

  access_choice="$(menu.tty "Select access mode:" \
    "local console only (no SSH user provisioning)" \
    "test access (SSH + default users/passwords)")"
  case "${access_choice}" in
    1)
      SELECTED_ACCESS_PROFILE="local_only"
      SELECTED_ENABLE_SSH="false"
      ;;
    2)
      SELECTED_ACCESS_PROFILE="test_access"
      SELECTED_ENABLE_SSH="true"
      ;;
  esac

  enable_ufw_choice="$(prompt.tty "Enable UFW inside the container? (yes|no)" "$(is.true "${FEATURE_ENABLE_UFW}" && printf yes || printf no)")"
  if is.true "${enable_ufw_choice}"; then
    SELECTED_ENABLE_UFW="true"
  else
    SELECTED_ENABLE_UFW="false"
  fi
}

confirm.selection() {
  printf '\nProposed Debian LXC action:\n' >&3
  printf '  mode:             %s\n' "${FEATURE_MODE}" >&3
  printf '  operation:        %s\n' "${SELECTED_OPERATION}" >&3
  printf '  ctid:             %s\n' "${SELECTED_CTID}" >&3
  printf '  hostname:         %s\n' "${SELECTED_HOSTNAME:-unchanged}" >&3
  printf '  template:         %s\n' "${SELECTED_TEMPLATE_NAME:-existing}" >&3
  printf '  template method:  %s\n' "${SELECTED_TEMPLATE_DOWNLOAD_METHOD:-none}" >&3
  if [[ -n "${SELECTED_TEMPLATE_URL:-}" ]]; then
    printf '  template url:     %s\n' "${SELECTED_TEMPLATE_URL}" >&3
  fi
  printf '  rootfs:           %s:%sG\n' "${SELECTED_ROOTFS_STORAGE:-n/a}" "${SELECTED_ROOTFS_SIZE_GB:-n/a}" >&3
  printf '  cores/mem/swap:   %s / %sMB / %sMB\n' "${SELECTED_CORES:-n/a}" "${SELECTED_MEMORY_MB:-n/a}" "${SELECTED_SWAP_MB:-n/a}" >&3
  printf '  bridge:           %s\n' "${SELECTED_BRIDGE:-n/a}" >&3
  printf '  vlan:             %s\n' "${SELECTED_VLAN_TAG:-none}" >&3
  printf '  ipv4 mode:        %s\n' "${SELECTED_IPV4_MODE:-n/a}" >&3
  if [[ "${SELECTED_IPV4_MODE:-}" == "static" ]]; then
    printf '  ipv4/gateway:     %s / %s\n' "${SELECTED_IPV4_CIDR}" "${SELECTED_GATEWAY}" >&3
  fi
  printf '  unprivileged:     %s\n' "${SELECTED_UNPRIVILEGED}" >&3
  printf '  nesting/fuse:     %s / %s\n' "${SELECTED_NESTING}" "${SELECTED_FUSE}" >&3
  printf '  hardening:        %s\n' "${SELECTED_HARDENING_PROFILE:-minimal}" >&3
  printf '  access profile:   %s\n' "${SELECTED_ACCESS_PROFILE}" >&3
  printf '  enable ssh:       %s\n' "${SELECTED_ENABLE_SSH}" >&3
  printf '  enable ufw:       %s\n' "${SELECTED_ENABLE_UFW}" >&3
  printf '  expected dns:     %s\n' "${DEFAULT_EXPECTED_DNS}" >&3
  printf '  internet probe:   %s\n' "${DEFAULT_INTERNET_PROBE_IPV4}" >&3
  if [[ "${SELECTED_ACCESS_PROFILE}" == "test_access" ]]; then
    local user
    printf '  default logins:\n' >&3
    for user in "${SELECTED_ACCESS_USERS[@]}"; do
      printf '    - %s / %s\n' "${user}" "${user}" >&3
    done
  fi
  if ((${#SELECTED_MOUNT_HOST_PATHS[@]} > 0)); then
    local i
    printf '  mountpoints:\n' >&3
    for i in "${!SELECTED_MOUNT_HOST_PATHS[@]}"; do
      printf '    - %s -> %s\n' "${SELECTED_MOUNT_HOST_PATHS[$i]}" "${SELECTED_MOUNT_CONTAINER_PATHS[$i]}" >&3
    done
  else
    printf '  mountpoints:      none\n' >&3
  fi
  local confirm
  confirm="$(prompt.tty "Type yes to continue" "no")"
  is.true "${confirm}" || {
    log.error "Operator aborted before mutation."
    exit 1
  }
}

collect.operator.selection() {
  normalize.allow.subnets
  normalize.access.users

  if ! is.true "${FEATURE_INTERACTIVE}" || ! open.tty; then
    SELECTED_OPERATION="${FEATURE_OPERATION:-create}"
    SELECTED_CTID="${DEFAULT_CTID}"
    SELECTED_HOSTNAME="${DEFAULT_HOSTNAME}"
    SELECTED_TEMPLATE_NAME="${DEFAULT_TEMPLATE}"
    SELECTED_ROOTFS_STORAGE="${DEFAULT_ROOTFS_STORAGE}"
    SELECTED_ROOTFS_SIZE_GB="${DEFAULT_ROOTFS_SIZE_GB}"
    SELECTED_CORES="${DEFAULT_CORES}"
    SELECTED_MEMORY_MB="${DEFAULT_MEMORY_MB}"
    SELECTED_SWAP_MB="${DEFAULT_SWAP_MB}"
    SELECTED_BRIDGE="${DEFAULT_BRIDGE}"
    SELECTED_VLAN_TAG="${DEFAULT_VLAN_TAG}"
    SELECTED_IPV4_MODE="${DEFAULT_IPV4_MODE}"
    SELECTED_IPV4_CIDR="${DEFAULT_IPV4_CIDR}"
    SELECTED_GATEWAY="${DEFAULT_GATEWAY}"
    SELECTED_UNPRIVILEGED="$(bool.yaml "${DEFAULT_UNPRIVILEGED}")"
    SELECTED_NESTING="$(bool.yaml "${DEFAULT_NESTING}")"
    SELECTED_FUSE="$(bool.yaml "${DEFAULT_FUSE}")"
    SELECTED_HARDENING_PROFILE="$(normalize.hardening.profile "${DEFAULT_HARDENING_PROFILE}")"
    SELECTED_ACCESS_PROFILE="$(normalize.access.profile "${DEFAULT_ACCESS_PROFILE}")"
    if [[ "${SELECTED_ACCESS_PROFILE}" == "test_access" ]]; then
      SELECTED_ENABLE_SSH="true"
    else
      SELECTED_ENABLE_SSH="false"
    fi
    SELECTED_ENABLE_UFW="$(bool.yaml "${FEATURE_ENABLE_UFW}")"
    [[ -n "${SELECTED_OPERATION}" ]] || {
      log.error "Interactive UI unavailable. Set PROXMOX_LXC_DEBIAN_OPERATION and related env vars."
      exit 1
    }
    [[ "${SELECTED_OPERATION}" != "create" || -n "${SELECTED_TEMPLATE_NAME}" ]] || {
      log.error "Non-interactive create mode requires PROXMOX_LXC_DEBIAN_TEMPLATE."
      exit 1
    }
    [[ -n "${SELECTED_CTID}" ]] || SELECTED_CTID="$(next.available.ctid)"
    if [[ "${SELECTED_OPERATION}" == "use_existing" ]]; then
      SELECTED_EXISTING_CTID="${SELECTED_CTID}"
    fi
    if [[ -n "${DEFAULT_MOUNTS}" ]]; then
      apply.mount.selection.defaults
    fi
    return 0
  fi

  print.discovery.summary
  select.operation.interactive
  if [[ "${FEATURE_MODE}" == "preflight" || "${SELECTED_OPERATION}" == "preflight" ]]; then
    return 0
  fi

  case "${SELECTED_OPERATION}" in
    use_existing)
      select.existing.container
      ;;
    create)
      collect.create.settings
      ;;
    *)
      log.error "Unsupported operation: ${SELECTED_OPERATION}"
      exit 1
      ;;
  esac

  collect.hardening.selection
  confirm.selection
}

write.selection.file() {
  mkdir -p "${FACTS_DIR}"
  cat > "${SELECTION_PATH}" <<EOF
---
proxmox_lxc_debian_operator_selection:
  confirmed: true
  source: "setup/lxc/debian.sh"
  mode: $(yaml.quote "${FEATURE_MODE}")
  operation: $(yaml.quote "${SELECTED_OPERATION}")
  ctid: $(yaml.quote "${SELECTED_CTID}")
  hostname: $(yaml.scalar.or.null "${SELECTED_HOSTNAME}")
  template:
    name: $(yaml.scalar.or.null "${SELECTED_TEMPLATE_NAME}")
    download_if_missing: $(bool.yaml "${SELECTED_TEMPLATE_DOWNLOAD_IF_MISSING}")
    download_method: $(yaml.scalar.or.null "${SELECTED_TEMPLATE_DOWNLOAD_METHOD}")
    url: $(yaml.scalar.or.null "${SELECTED_TEMPLATE_URL}")
    storage: "local"
  resources:
    rootfs_storage: $(yaml.scalar.or.null "${SELECTED_ROOTFS_STORAGE}")
    rootfs_size_gb: ${SELECTED_ROOTFS_SIZE_GB:-0}
    cores: ${SELECTED_CORES:-0}
    memory_mb: ${SELECTED_MEMORY_MB:-0}
    swap_mb: ${SELECTED_SWAP_MB:-0}
    unprivileged: $(bool.yaml "${SELECTED_UNPRIVILEGED}")
    nesting: $(bool.yaml "${SELECTED_NESTING}")
    fuse: $(bool.yaml "${SELECTED_FUSE}")
  network:
    bridge: $(yaml.scalar.or.null "${SELECTED_BRIDGE}")
    vlan_tag: $(yaml.scalar.or.null "${SELECTED_VLAN_TAG}")
    ipv4_mode: $(yaml.scalar.or.null "${SELECTED_IPV4_MODE}")
    ipv4_cidr: $(yaml.scalar.or.null "${SELECTED_IPV4_CIDR}")
    gateway: $(yaml.scalar.or.null "${SELECTED_GATEWAY}")
  hardening:
    profile: $(yaml.scalar.or.null "${SELECTED_HARDENING_PROFILE}")
    access_profile: $(yaml.scalar.or.null "${SELECTED_ACCESS_PROFILE}")
    enable_ssh: $(bool.yaml "${SELECTED_ENABLE_SSH}")
    enable_ufw: $(bool.yaml "${SELECTED_ENABLE_UFW}")
    allow_subnets:
$(for subnet in "${SELECTED_ALLOW_SUBNETS[@]}"; do printf '      - %s\n' "$(yaml.quote "${subnet}")"; done)
    users:
$(for user in "${SELECTED_ACCESS_USERS[@]}"; do printf '      - name: %s\n        password: %s\n' "$(yaml.quote "${user}")" "$(yaml.quote "${user}")"; done)
    expected_dns: $(yaml.scalar.or.null "${DEFAULT_EXPECTED_DNS}")
    internet_probe_ipv4: $(yaml.scalar.or.null "${DEFAULT_INTERNET_PROBE_IPV4}")
EOF
  if ((${#SELECTED_MOUNT_HOST_PATHS[@]} > 0)); then
    printf '  mountpoints:\n' >> "${SELECTION_PATH}"
    local i
    for i in "${!SELECTED_MOUNT_HOST_PATHS[@]}"; do
      printf '    - host_path: %s\n      container_path: %s\n      backup: false\n' \
        "$(yaml.quote "${SELECTED_MOUNT_HOST_PATHS[$i]}")" \
        "$(yaml.quote "${SELECTED_MOUNT_CONTAINER_PATHS[$i]}")" >> "${SELECTION_PATH}"
    done
  else
    printf '  mountpoints: []\n' >> "${SELECTION_PATH}"
  fi
}

write.runtime.facts() {
  mkdir -p "${FACTS_DIR}"
  cat > "${RUNTIME_FACTS_PATH}" <<EOF
---
proxmox_lxc_debian_runtime:
  mode: $(yaml.quote "${FEATURE_MODE}")
  operation: $(yaml.quote "${SELECTED_OPERATION:-preflight}")
  containers_tsv_path: $(yaml.quote "${CONTAINERS_TSV_PATH}")
  templates_tsv_path: $(yaml.quote "${TEMPLATES_TSV_PATH}")
  isos_tsv_path: $(yaml.quote "${ISOS_TSV_PATH}")
  selection_path: $(yaml.quote "${SELECTION_PATH}")
EOF
}

write.debian.extra.vars.file() {
  mkdir -p "${TMP_DIR}"
  cat > "${DEBIAN_LXC_EXTRA_VARS_PATH}" <<EOF
---
proxmox_feature_defaults:
  debian_lxc:
    enabled: true
    mode: $(yaml.quote "${FEATURE_MODE}")
    require_proxmox_host: true
    require_operator_selection: true

proxmox_feature_facts_dir: $(yaml.quote "${FACTS_DIR}")
proxmox_lxc_debian:
  facts_dir: $(yaml.quote "${FACTS_DIR}")
  containers_tsv_path: $(yaml.quote "${CONTAINERS_TSV_PATH}")
  templates_tsv_path: $(yaml.quote "${TEMPLATES_TSV_PATH}")
  isos_tsv_path: $(yaml.quote "${ISOS_TSV_PATH}")
  selection_path: $(yaml.quote "${SELECTION_PATH}")
  runtime_facts_path: $(yaml.quote "${RUNTIME_FACTS_PATH}")
EOF
  log "Prepared Debian LXC extra-vars: ${DEBIAN_LXC_EXTRA_VARS_PATH}"
}

run.debian.feature() {
  discover.containers
  discover.local.templates
  discover.storage
  discover.bridges
  discover.isos
  load.netboot.catalog
  discover.mountpoints
  collect.operator.selection
  write.runtime.facts

  if [[ "${FEATURE_MODE}" == "preflight" || "${SELECTED_OPERATION:-}" == "preflight" ]]; then
    print.discovery.summary
    log "Preflight complete. No changes were applied."
    return 0
  fi

  write.selection.file
  write.debian.extra.vars.file

  log "Running Proxmox Debian LXC feature in mode=${FEATURE_MODE}..."
  run.feature.playbook "${DEBIAN_LXC_PLAYBOOK_PATH}" -e "@${DEBIAN_LXC_EXTRA_VARS_PATH}"

  run.feature.playbook "${DEBIAN_BASE_PLAYBOOK_PATH}" -e "@${DEBIAN_LXC_EXTRA_VARS_PATH}"

  log "Suggested next step:"
  log "pct exec ${SELECTED_CTID} -- bash -lc 'wget -qO- https://devs-guide.github.io/proxmox/setup/lxc/samba.sh | bash'"
}

main() {
  require.root
  require.apt
  require.valid.mode
  require.proxmox.host
  ensure.managed.ansible
  prepare.feature.files
  run.debian.feature
}

main "$@"
