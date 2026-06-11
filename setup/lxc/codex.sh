#!/usr/bin/env bash
## Manual Proxmox LXC Codex feature runner.
## Local usage:
##   ./setup/lxc/codex.sh [preflight|apply]
## Published usage:
##   wget -qO- https://devs-guide.github.io/proxmox/setup/lxc/codex.sh | bash

set -euo pipefail

log()       { printf '[setup.lxc.codex] %s\n' "$*" >&2; }
log.error() { printf '[setup.lxc.codex][error] %s\n' "$*" >&2; }

TMP_DIR="/tmp/pve-feature-lxc-codex"
PAGES_BASE_URL="https://devs-guide.github.io/proxmox"
PLAYBOOK_ROOT="${TMP_DIR}/ansible"
PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
PLAYBOOK_DEBIAN_DIR="${PLAYBOOK_ROOT}/debian"
PLAYBOOK_PROXMOX_CONTAINER_DIR="${PLAYBOOK_ROOT}/proxmox/container"
LOCAL_COMMON_HELPER="../../bootstrap/release.common.sh"
COMMON_HELPER_NAME="release.common.sh"
COMMON_HELPER_URL="${PAGES_BASE_URL}/${COMMON_HELPER_NAME}"
COMMON_HELPER_PATH="${TMP_DIR}/${COMMON_HELPER_NAME}"
LXC_COMMON_HELPER_NAME="common.sh"
GROUP_VARS_FILE="proxmox.yml"
GROUP_VARS_URL="${PAGES_BASE_URL}/ansible/group_vars/${GROUP_VARS_FILE}"
GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
FEATURE_PLAYBOOKS=(
  "proxmox/container/node.yml"
  "proxmox/container/codex.yml"
)
FEATURE_SUPPORT_FILES=(
  "debian/node.yml"
  "debian/cli.codex.yml"
  "proxmox/container/common.yml"
)
NODE_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[0]}"
CODEX_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[1]}"
NODE_SUPPORT_PLAYBOOK_REL="${FEATURE_SUPPORT_FILES[0]}"
CODEX_SUPPORT_PLAYBOOK_REL="${FEATURE_SUPPORT_FILES[1]}"
CONTAINER_COMMON_SUPPORT_FILE_REL="${FEATURE_SUPPORT_FILES[2]}"
NODE_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${NODE_PLAYBOOK_REL}"
CODEX_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${CODEX_PLAYBOOK_REL}"
NODE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NODE_PLAYBOOK_REL}"
CODEX_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${CODEX_PLAYBOOK_REL}"
NODE_SUPPORT_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${NODE_SUPPORT_PLAYBOOK_REL}"
CODEX_SUPPORT_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${CODEX_SUPPORT_PLAYBOOK_REL}"
NODE_SUPPORT_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NODE_SUPPORT_PLAYBOOK_REL}"
CODEX_SUPPORT_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${CODEX_SUPPORT_PLAYBOOK_REL}"
CONTAINER_COMMON_SUPPORT_FILE_URL="${PAGES_BASE_URL}/ansible/${CONTAINER_COMMON_SUPPORT_FILE_REL}"
CONTAINER_COMMON_SUPPORT_FILE_PATH="${PLAYBOOK_ROOT}/${CONTAINER_COMMON_SUPPORT_FILE_REL}"
LXC_CODEX_EXTRA_VARS_PATH="${TMP_DIR}/lxc.codex.extra-vars.yml"
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
FACTS_DIR="${PROXMOX_LXC_CODEX_FACTS_DIR:-/etc/ansible/proxmox/facts}"
NODE_RUNTIME_FACTS_PATH="${PROXMOX_LXC_CODEX_NODE_RUNTIME_FACTS_PATH:-${FACTS_DIR}/lxc.codex.node.yml}"
CODEX_RUNTIME_FACTS_PATH="${PROXMOX_LXC_CODEX_RUNTIME_FACTS_PATH:-${FACTS_DIR}/lxc.codex.yml}"
FEATURE_MODE="${1:-${PROXMOX_LXC_CODEX_MODE:-apply}}"
FEATURE_REQUIRE_CONTAINER="${PROXMOX_LXC_CODEX_REQUIRE_CONTAINER:-1}"
FEATURE_ALLOW_HOST="${PROXMOX_LXC_CODEX_ALLOW_HOST:-0}"
FEATURE_ASSUME_CONTAINER="${PROXMOX_LXC_CODEX_ASSUME_CONTAINER:-0}"
NODE_NVM_VERSION="${PROXMOX_LXC_CODEX_NVM_VERSION:-v0.40.4}"
NODE_VERSION="${PROXMOX_LXC_CODEX_NODE_VERSION:-lts/*}"
NODE_INSTALL_SCOPE="${PROXMOX_LXC_CODEX_NODE_INSTALL_SCOPE:-shared}"
NODE_SHARED_NVM_DIR="${PROXMOX_LXC_CODEX_NODE_SHARED_NVM_DIR:-/usr/local/lib/nvm}"
NODE_NVM_DIR="${PROXMOX_LXC_CODEX_NODE_NVM_DIR:-}"
if [[ -z "${NODE_NVM_DIR}" ]]; then
  case "${NODE_INSTALL_SCOPE}" in
    shared) NODE_NVM_DIR="${NODE_SHARED_NVM_DIR}" ;;
    *) NODE_NVM_DIR="/root/.nvm" ;;
  esac
fi
NODE_NPM_POLICY="${PROXMOX_LXC_CODEX_NODE_NPM_POLICY:-bundled}"
NODE_NPM_VERSION="${PROXMOX_LXC_CODEX_NODE_NPM_VERSION:-}"
NODE_CREATE_SYSTEM_SYMLINKS="${PROXMOX_LXC_CODEX_NODE_CREATE_SYSTEM_SYMLINKS:-1}"
NODE_ENABLE_COREPACK="${PROXMOX_LXC_CODEX_NODE_ENABLE_COREPACK:-0}"
CODEX_NPM_PACKAGE="${PROXMOX_LXC_CODEX_PACKAGE:-@openai/codex}"
CODEX_VERSION="${PROXMOX_LXC_CODEX_VERSION:-latest}"
CODEX_INSTALL_DOCS_MCP="${PROXMOX_LXC_CODEX_INSTALL_DOCS_MCP:-1}"
CODEX_DOCS_MCP_NAME="${PROXMOX_LXC_CODEX_DOCS_MCP_NAME:-openaiDeveloperDocs}"
CODEX_DOCS_MCP_URL="${PROXMOX_LXC_CODEX_DOCS_MCP_URL:-https://developers.openai.com/mcp}"
CODEX_SELF_URL="${PROXMOX_LXC_CODEX_SELF_URL:-${PAGES_BASE_URL}/setup/lxc/codex.sh}"
CODEX_SUDO_REEXEC="${PROXMOX_LXC_CODEX_SUDO_REEXEC:-0}"
CONTAINER_OS_PRETTY=""

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
  # shellcheck source=/tmp/pve-feature-lxc-codex/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

source.release.common

collect.sudo.env.args() {
  local -n _out="$1"

  _out=(
    "PROXMOX_LXC_CODEX_MODE=${FEATURE_MODE}"
    "PROXMOX_LXC_CODEX_REQUIRE_CONTAINER=${FEATURE_REQUIRE_CONTAINER}"
    "PROXMOX_LXC_CODEX_ALLOW_HOST=${FEATURE_ALLOW_HOST}"
    "PROXMOX_LXC_CODEX_ASSUME_CONTAINER=${FEATURE_ASSUME_CONTAINER}"
    "PROXMOX_LXC_CODEX_NVM_VERSION=${NODE_NVM_VERSION}"
    "PROXMOX_LXC_CODEX_NODE_VERSION=${NODE_VERSION}"
    "PROXMOX_LXC_CODEX_NODE_INSTALL_SCOPE=${NODE_INSTALL_SCOPE}"
    "PROXMOX_LXC_CODEX_NODE_SHARED_NVM_DIR=${NODE_SHARED_NVM_DIR}"
    "PROXMOX_LXC_CODEX_NODE_NVM_DIR=${NODE_NVM_DIR}"
    "PROXMOX_LXC_CODEX_NODE_NPM_POLICY=${NODE_NPM_POLICY}"
    "PROXMOX_LXC_CODEX_NODE_NPM_VERSION=${NODE_NPM_VERSION}"
    "PROXMOX_LXC_CODEX_NODE_CREATE_SYSTEM_SYMLINKS=${NODE_CREATE_SYSTEM_SYMLINKS}"
    "PROXMOX_LXC_CODEX_NODE_ENABLE_COREPACK=${NODE_ENABLE_COREPACK}"
    "PROXMOX_LXC_CODEX_PACKAGE=${CODEX_NPM_PACKAGE}"
    "PROXMOX_LXC_CODEX_VERSION=${CODEX_VERSION}"
    "PROXMOX_LXC_CODEX_INSTALL_DOCS_MCP=${CODEX_INSTALL_DOCS_MCP}"
    "PROXMOX_LXC_CODEX_DOCS_MCP_NAME=${CODEX_DOCS_MCP_NAME}"
    "PROXMOX_LXC_CODEX_DOCS_MCP_URL=${CODEX_DOCS_MCP_URL}"
    "PROXMOX_LXC_CODEX_SANDBOX_PACKAGE=${PROXMOX_LXC_CODEX_SANDBOX_PACKAGE}"
    "PROXMOX_LXC_CODEX_SANDBOX_BINARY=${PROXMOX_LXC_CODEX_SANDBOX_BINARY}"
    "PROXMOX_LXC_CODEX_FACTS_DIR=${FACTS_DIR}"
    "PROXMOX_LXC_CODEX_NODE_RUNTIME_FACTS_PATH=${NODE_RUNTIME_FACTS_PATH}"
    "PROXMOX_LXC_CODEX_RUNTIME_FACTS_PATH=${CODEX_RUNTIME_FACTS_PATH}"
    "PROXMOX_LXC_CODEX_SELF_URL=${CODEX_SELF_URL}"
    "PROXMOX_LXC_CODEX_SUDO_REEXEC=1"
    "PAGES_BASE_URL=${PAGES_BASE_URL}"
    "TMP_DIR=${TMP_DIR}"
  )
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

bool.yaml() {
  if is.true "${1:-false}"; then
    printf 'true'
  else
    printf 'false'
  fi
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
      log.error "This Codex feature must run inside a Debian LXC container, not on the Proxmox host."
      exit 1
    fi
  fi

  if is.true "${FEATURE_REQUIRE_CONTAINER}" && ((detected_container == 0)); then
    log.error "Container execution could not be confirmed. Re-run with PROXMOX_LXC_CODEX_ASSUME_CONTAINER=1 only if you are already inside the LXC."
    exit 1
  fi
}

use.local.feature.files() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/../.." && pwd)"

  if [[ -r "${repo_root}/ansible/${NODE_PLAYBOOK_REL}" \
        && -r "${repo_root}/ansible/${CODEX_PLAYBOOK_REL}" \
        && -r "${repo_root}/ansible/${NODE_SUPPORT_PLAYBOOK_REL}" \
        && -r "${repo_root}/ansible/${CODEX_SUPPORT_PLAYBOOK_REL}" \
        && -r "${repo_root}/ansible/${CONTAINER_COMMON_SUPPORT_FILE_REL}" \
        && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]]; then
    PLAYBOOK_ROOT="${repo_root}/ansible"
    PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
    PLAYBOOK_DEBIAN_DIR="${PLAYBOOK_ROOT}/debian"
    PLAYBOOK_PROXMOX_CONTAINER_DIR="${PLAYBOOK_ROOT}/proxmox/container"
    GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
    NODE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NODE_PLAYBOOK_REL}"
    CODEX_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${CODEX_PLAYBOOK_REL}"
    NODE_SUPPORT_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NODE_SUPPORT_PLAYBOOK_REL}"
    CODEX_SUPPORT_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${CODEX_SUPPORT_PLAYBOOK_REL}"
    CONTAINER_COMMON_SUPPORT_FILE_PATH="${PLAYBOOK_ROOT}/${CONTAINER_COMMON_SUPPORT_FILE_REL}"
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

  mkdir -p "${PLAYBOOK_GROUP_VARS_DIR}" "${PLAYBOOK_DEBIAN_DIR}" "${PLAYBOOK_PROXMOX_CONTAINER_DIR}"
  fetch.feature.file "${GROUP_VARS_URL}" "${GROUP_VARS_PATH}"
  fetch.feature.file "${NODE_SUPPORT_PLAYBOOK_URL}" "${NODE_SUPPORT_PLAYBOOK_PATH}"
  fetch.feature.file "${CODEX_SUPPORT_PLAYBOOK_URL}" "${CODEX_SUPPORT_PLAYBOOK_PATH}"
  fetch.feature.file "${CONTAINER_COMMON_SUPPORT_FILE_URL}" "${CONTAINER_COMMON_SUPPORT_FILE_PATH}"
  fetch.feature.file "${NODE_PLAYBOOK_URL}" "${NODE_PLAYBOOK_PATH}"
  fetch.feature.file "${CODEX_PLAYBOOK_URL}" "${CODEX_PLAYBOOK_PATH}"
}

run.feature.playbook() {
  local playbook_path="$1"
  shift
  "${ANSIBLE_VENV_BIN}" -i localhost, -c local -e "@${GROUP_VARS_PATH}" "$@" "${playbook_path}"
}

write.lxc.codex.extra.vars.file() {
  mkdir -p "${TMP_DIR}"
  cat > "${LXC_CODEX_EXTRA_VARS_PATH}" <<EOF
---
proxmox_feature_defaults:
  lxc_codex:
    enabled: true
    mode: $(yaml.quote "${FEATURE_MODE}")
    require_container: $(bool.yaml "${FEATURE_REQUIRE_CONTAINER}")

proxmox_feature_facts_dir: $(yaml.quote "${FACTS_DIR}")

ansible_python_interpreter_managed: "/usr/bin/python3"

node_enable: true
node_mode: $(yaml.quote "${FEATURE_MODE}")
node_nvm_version: $(yaml.quote "${NODE_NVM_VERSION}")
node_install_scope: $(yaml.quote "${NODE_INSTALL_SCOPE}")
node_shared_nvm_dir: $(yaml.quote "${NODE_SHARED_NVM_DIR}")
node_nvm_dir: $(yaml.quote "${NODE_NVM_DIR}")
node_version: $(yaml.quote "${NODE_VERSION}")
node_npm_policy: $(yaml.quote "${NODE_NPM_POLICY}")
node_npm_version: $(yaml.quote "${NODE_NPM_VERSION}")
node_create_system_symlinks: $(bool.yaml "${NODE_CREATE_SYSTEM_SYMLINKS}")
node_enable_corepack: $(bool.yaml "${NODE_ENABLE_COREPACK}")
node_runtime_facts_path: $(yaml.quote "${NODE_RUNTIME_FACTS_PATH}")

codex_enable: true
codex_mode: $(yaml.quote "${FEATURE_MODE}")
codex_node_install_scope: $(yaml.quote "${NODE_INSTALL_SCOPE}")
codex_node_shared_nvm_dir: $(yaml.quote "${NODE_SHARED_NVM_DIR}")
codex_nvm_dir: $(yaml.quote "${NODE_NVM_DIR}")
codex_npm_package: $(yaml.quote "${CODEX_NPM_PACKAGE}")
codex_version: $(yaml.quote "${CODEX_VERSION}")
codex_install_docs_mcp: $(bool.yaml "${CODEX_INSTALL_DOCS_MCP}")
codex_docs_mcp_name: $(yaml.quote "${CODEX_DOCS_MCP_NAME}")
codex_docs_mcp_url: $(yaml.quote "${CODEX_DOCS_MCP_URL}")
codex_runtime_facts_path: $(yaml.quote "${CODEX_RUNTIME_FACTS_PATH}")

proxmox_lxc_codex_runtime_packages:
  - $(yaml.quote "${PROXMOX_LXC_CODEX_SANDBOX_PACKAGE}")
proxmox_lxc_codex_runtime_binaries:
  - name: $(yaml.quote "${PROXMOX_LXC_CODEX_SANDBOX_PACKAGE}")
    command: $(yaml.quote "${PROXMOX_LXC_CODEX_SANDBOX_BINARY}")
EOF
  log "Prepared LXC Codex extra-vars: ${LXC_CODEX_EXTRA_VARS_PATH}"
}

run.lxc.codex.feature() {
  write.lxc.codex.extra.vars.file
  log "Container OS: ${CONTAINER_OS_PRETTY}"
  log "Node install scope: ${NODE_INSTALL_SCOPE}"
  log "Node nvm dir: ${NODE_NVM_DIR}"
  log "Desired Node version: ${NODE_VERSION}"
  log "Desired Codex package: ${CODEX_NPM_PACKAGE}"
  log "Desired Codex version: ${CODEX_VERSION}"
  log "Running Debian Node feature in mode=${FEATURE_MODE}..."
  run.feature.playbook "${NODE_PLAYBOOK_PATH}" -e "@${LXC_CODEX_EXTRA_VARS_PATH}"
  log "Running LXC Codex feature in mode=${FEATURE_MODE}..."
  run.feature.playbook "${CODEX_PLAYBOOK_PATH}" -e "@${LXC_CODEX_EXTRA_VARS_PATH}"
  lxc.common.report.binary.status "Codex sandbox helper" "${PROXMOX_LXC_CODEX_SANDBOX_BINARY}" || true
}

main() {
  ensure.root.or.sudo.reexec "${CODEX_SUDO_REEXEC}" "${CODEX_SELF_URL}" "$@"
  require.root
  require.apt
  require.valid.mode
  require.debian.container
  require.container.not.host
  ensure.container.ansible
  prepare.feature.files
  run.lxc.codex.feature
}

main "$@"
