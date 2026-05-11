#!/usr/bin/env bash
## Manual Proxmox Node + Codex feature runner.
## Local usage:
##   ./setup/cli.codex.sh [preflight|apply]
## Published usage:
##   wget -qO- https://devs-guide.github.io/proxmox/setup.cli.codex.sh | bash

set -euo pipefail

log()       { printf '[setup.cli.codex] %s\n' "$*" >&2; }
log.error() { printf '[setup.cli.codex][error] %s\n' "$*" >&2; }

TMP_DIR="/tmp/pve-feature-cli-codex"
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
  "debian/node.yml"
  "debian/codex.yml"
)
NODE_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[0]}"
CODEX_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[1]}"
NODE_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${NODE_PLAYBOOK_REL}"
CODEX_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${CODEX_PLAYBOOK_REL}"
NODE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NODE_PLAYBOOK_REL}"
CODEX_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${CODEX_PLAYBOOK_REL}"
CLI_CODEX_EXTRA_VARS_PATH="${TMP_DIR}/cli.codex.extra-vars.yml"
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
FEATURE_MODE="${1:-${PROXMOX_CLI_CODEX_MODE:-apply}}"
NODE_NVM_VERSION="${PROXMOX_CLI_CODEX_NVM_VERSION:-v0.39.7}"
NODE_VERSION="${PROXMOX_CLI_CODEX_NODE_VERSION:-lts/*}"
CODEX_NPM_PACKAGE="${PROXMOX_CLI_CODEX_PACKAGE:-@openai/codex}"
CODEX_VERSION="${PROXMOX_CLI_CODEX_VERSION:-latest}"
CODEX_INSTALL_DOCS_MCP="${PROXMOX_CLI_CODEX_INSTALL_DOCS_MCP:-1}"
CODEX_DOCS_MCP_NAME="${PROXMOX_CLI_CODEX_DOCS_MCP_NAME:-openaiDeveloperDocs}"
CODEX_DOCS_MCP_URL="${PROXMOX_CLI_CODEX_DOCS_MCP_URL:-https://developers.openai.com/mcp}"
FACTS_DIR="${PROXMOX_CLI_CODEX_FACTS_DIR:-/etc/ansible/proxmox/facts}"
CODEX_RUNTIME_FACTS_PATH="${PROXMOX_CLI_CODEX_RUNTIME_FACTS_PATH:-${FACTS_DIR}/cli.codex.yml}"

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
  # shellcheck source=/tmp/pve-feature-cli-codex/release.common.sh
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

bool.yaml() {
  if is.true "${1:-false}"; then
    printf 'true'
  else
    printf 'false'
  fi
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
    preflight|apply) ;;
    *)
      log.error "Unsupported mode: ${FEATURE_MODE}"
      log.error "Use one of: preflight, apply"
      exit 1
      ;;
  esac
}

use.local.feature.files() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"

  if [[ -r "${repo_root}/ansible/${NODE_PLAYBOOK_REL}" && -r "${repo_root}/ansible/${CODEX_PLAYBOOK_REL}" && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]]; then
    PLAYBOOK_ROOT="${repo_root}/ansible"
    PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
    GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
    NODE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${NODE_PLAYBOOK_REL}"
    CODEX_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${CODEX_PLAYBOOK_REL}"
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
  fetch.feature.file "${NODE_PLAYBOOK_URL}" "${NODE_PLAYBOOK_PATH}"
  fetch.feature.file "${CODEX_PLAYBOOK_URL}" "${CODEX_PLAYBOOK_PATH}"
}

run.feature.playbook() {
  local playbook_path="$1"
  shift
  "${ANSIBLE_VENV_BIN}" -i localhost, -c local -e "@${GROUP_VARS_PATH}" "$@" "${playbook_path}"
}

write.cli.codex.extra.vars.file() {
  mkdir -p "${TMP_DIR}"
  cat > "${CLI_CODEX_EXTRA_VARS_PATH}" <<EOF
---
proxmox_feature_defaults:
  cli_codex:
    enabled: true
    mode: $(yaml.quote "${FEATURE_MODE}")

ansible_python_interpreter_managed: "/usr/bin/python3"

node_enable: true
nvm_version: $(yaml.quote "${NODE_NVM_VERSION}")
node_version: $(yaml.quote "${NODE_VERSION}")

codex_enable: true
codex_mode: $(yaml.quote "${FEATURE_MODE}")
codex_npm_package: $(yaml.quote "${CODEX_NPM_PACKAGE}")
codex_version: $(yaml.quote "${CODEX_VERSION}")
codex_install_docs_mcp: $(bool.yaml "${CODEX_INSTALL_DOCS_MCP}")
codex_docs_mcp_name: $(yaml.quote "${CODEX_DOCS_MCP_NAME}")
codex_docs_mcp_url: $(yaml.quote "${CODEX_DOCS_MCP_URL}")
codex_runtime_facts_path: $(yaml.quote "${CODEX_RUNTIME_FACTS_PATH}")
EOF
  log "Prepared CLI/Codex extra-vars: ${CLI_CODEX_EXTRA_VARS_PATH}"
}

run.preflight() {
  log "Feature mode: ${FEATURE_MODE}"
  log "Target node runtime: Proxmox host"
  log "Desired Node version: ${NODE_VERSION}"
  log "Desired Codex package: ${CODEX_NPM_PACKAGE}"
  log "Desired Codex version: ${CODEX_VERSION}"
  log "OpenAI docs MCP bootstrap: ${CODEX_INSTALL_DOCS_MCP}"

  if command -v node >/dev/null 2>&1; then
    log "Existing node: $(node --version 2>/dev/null)"
  else
    log "Existing node: not installed"
  fi

  if command -v npm >/dev/null 2>&1; then
    log "Existing npm: $(npm --version 2>/dev/null)"
  else
    log "Existing npm: not installed"
  fi

  if command -v codex >/dev/null 2>&1; then
    log "Existing codex: $(codex --version 2>/dev/null)"
  else
    log "Existing codex: not installed"
  fi

  log "Apply command:"
  log "  wget -qO- ${PAGES_BASE_URL}/setup.cli.codex.sh | bash"
}

run.cli.codex.feature() {
  write.cli.codex.extra.vars.file
  log "Running Debian Node feature..."
  run.feature.playbook "${NODE_PLAYBOOK_PATH}" -e "@${CLI_CODEX_EXTRA_VARS_PATH}"
  log "Running Debian Codex feature..."
  run.feature.playbook "${CODEX_PLAYBOOK_PATH}" -e "@${CLI_CODEX_EXTRA_VARS_PATH}"
}

main() {
  require.root
  require.apt
  require.proxmox
  require.valid.mode

  if [[ "${FEATURE_MODE}" == "preflight" ]]; then
    run.preflight
    exit 0
  fi

  ensure.container.ansible
  prepare.feature.files
  run.cli.codex.feature
}

main "$@"
