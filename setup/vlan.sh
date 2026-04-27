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
PLAYBOOK_PROXMOX_DIR="${PLAYBOOK_ROOT}/proxmox"
PLAYBOOK_HELPER_DIR="${PLAYBOOK_PROXMOX_DIR}/helper"
PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
LOCAL_COMMON_HELPER="../bootstrap/release.common.sh"
COMMON_HELPER_NAME="release.common.sh"
COMMON_HELPER_URL="${PAGES_BASE_URL}/${COMMON_HELPER_NAME}"
COMMON_HELPER_PATH="${TMP_DIR}/${COMMON_HELPER_NAME}"
GROUP_VARS_FILE="proxmox.yml"
GROUP_VARS_URL="${PAGES_BASE_URL}/ansible/group_vars/${GROUP_VARS_FILE}"
GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
HARDWARE_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/proxmox/helper/hardware.yml"
HARDWARE_PLAYBOOK_PATH="${PLAYBOOK_HELPER_DIR}/hardware.yml"
VLAN_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/proxmox/vlan.yml"
VLAN_PLAYBOOK_PATH="${PLAYBOOK_PROXMOX_DIR}/vlan.yml"
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

use.local.feature.files() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"

  if [[ -r "${repo_root}/ansible/proxmox/helper/hardware.yml" && -r "${repo_root}/ansible/proxmox/vlan.yml" && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]]; then
    PLAYBOOK_ROOT="${repo_root}/ansible"
    PLAYBOOK_PROXMOX_DIR="${PLAYBOOK_ROOT}/proxmox"
    PLAYBOOK_HELPER_DIR="${PLAYBOOK_PROXMOX_DIR}/helper"
    PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
    GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
    HARDWARE_PLAYBOOK_PATH="${PLAYBOOK_HELPER_DIR}/hardware.yml"
    VLAN_PLAYBOOK_PATH="${PLAYBOOK_PROXMOX_DIR}/vlan.yml"
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

  mkdir -p "${PLAYBOOK_HELPER_DIR}" "${PLAYBOOK_GROUP_VARS_DIR}"
  fetch.feature.file "${GROUP_VARS_URL}" "${GROUP_VARS_PATH}"
  fetch.feature.file "${HARDWARE_PLAYBOOK_URL}" "${HARDWARE_PLAYBOOK_PATH}"
  fetch.feature.file "${VLAN_PLAYBOOK_URL}" "${VLAN_PLAYBOOK_PATH}"
}

run.feature.playbook() {
  local playbook_path="$1"
  shift
  "${ANSIBLE_VENV_BIN}" -i localhost, -c local -e "@${GROUP_VARS_PATH}" "$@" "${playbook_path}"
}

run.vlan.feature() {
  log "Running Proxmox hardware discovery helper..."
  run.feature.playbook "${HARDWARE_PLAYBOOK_PATH}"

  log "Running Proxmox VLAN feature in mode=${FEATURE_MODE}..."
  run.feature.playbook \
    "${VLAN_PLAYBOOK_PATH}" \
    -e "proxmox_feature_defaults.vlan.enabled=true" \
    -e "proxmox_feature_defaults.vlan.mode=${FEATURE_MODE}" \
    -e "proxmox_feature_defaults.vlan.use_discovered_hardware=${FEATURE_USE_DISCOVERY}"
}

main() {
  require.root
  require.apt
  require.proxmox
  require.valid.mode
  require.baseline.ready
  require.oob.ack
  ensure.managed.ansible
  prepare.feature.files
  run.vlan.feature
}

main "$@"
