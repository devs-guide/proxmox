#!/usr/bin/env bash
## PVE 9 shared Codex CLI setup.
##   wget -qO- https://devs-guide.github.io/proxmox/setup/cli/codex.sh | bash
##   wget -qO- https://devs-guide.github.io/proxmox/setup/cli/codex.sh | bash -s -- preflight

set -euo pipefail

log() { printf '[setup.cli.codex] %s\n' "$*" >&2; }
log.error() { printf '[setup.cli.codex][error] %s\n' "$*" >&2; }

TMP_DIR="${TMP_DIR:-/tmp/pve-feature-cli-codex}"
PAGES_BASE_URL="${PAGES_BASE_URL:-https://devs-guide.github.io/proxmox}"
PLAYBOOK_ROOT="${TMP_DIR}/ansible"
LOCAL_COMMON_HELPER="../../bootstrap/release.common.sh"
COMMON_HELPER_PATH="${TMP_DIR}/release.common.sh"
GROUP_VARS_FILE="proxmox.yml"
GROUP_VARS_PATH="${PLAYBOOK_ROOT}/group_vars/${GROUP_VARS_FILE}"
FEATURE_PLAYBOOKS=("proxmox/cli/codex.yml")
FEATURE_SUPPORT_FILES=("proxmox/pve/guard.yml" "debian/cli.codex.yml")
CODEX_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${FEATURE_PLAYBOOKS[0]}"
EXTRA_VARS_PATH="${TMP_DIR}/cli.codex.extra-vars.yml"
if [[ "${PROXMOX_RUNNER_SOURCE_ONLY:-0}" == 1 ]]; then
  FEATURE_MODE="${PROXMOX_CLI_CODEX_MODE:-apply}"
else
  FEATURE_MODE="${1:-${PROXMOX_CLI_CODEX_MODE:-apply}}"
fi
NODE_SHARED_NVM_DIR="${PROXMOX_CLI_CODEX_SHARED_NVM_DIR:-/usr/local/lib/nvm}"
CODEX_NPM_PACKAGE="${PROXMOX_CLI_CODEX_PACKAGE:-@openai/codex}"
CODEX_VERSION="${PROXMOX_CLI_CODEX_VERSION:-latest}"
CODEX_FACTS_PATH="${PROXMOX_CLI_CODEX_FACTS_PATH:-/etc/ansible/proxmox/facts/cli.codex.yml}"
PROXMOX_RUNTIME_CONTEXT="host"
PVE_OS_RELEASE_PATH="${PROXMOX_TEST_OS_RELEASE_PATH:-/etc/os-release}"

source.release.common() {
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fi
  if [[ -n "${script_dir}" && -r "${script_dir}/${LOCAL_COMMON_HELPER}" ]]; then
    # shellcheck source=bootstrap/release.common.sh
    source "${script_dir}/${LOCAL_COMMON_HELPER}"
    return
  fi
  mkdir -p "${TMP_DIR}"
  wget -qO "${COMMON_HELPER_PATH}" "${PAGES_BASE_URL}/release.common.sh"
  [[ -s "${COMMON_HELPER_PATH}" ]] || { log.error 'Downloaded release.common.sh is empty.'; exit 1; }
  # shellcheck source=/tmp/pve-feature-cli-codex/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

yaml.quote() { local value="${1:-}"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; printf '"%s"' "${value}"; }

require.valid.mode() { case "${FEATURE_MODE}" in preflight|apply) ;; *) log.error "Unsupported mode: ${FEATURE_MODE}."; exit 1 ;; esac; }

require.pve9.trixie.host() {
  local version="" codename="" container=""
  command -v pveversion >/dev/null 2>&1 || { log.error 'This runner requires Proxmox VE.'; exit 1; }
  version="$(pveversion 2>/dev/null || true)"
  [[ "${version}" == pve-manager/9.* ]] || { log.error "PVE 9 is required; observed ${version:-unknown}."; exit 1; }
  if [[ -r "${PVE_OS_RELEASE_PATH}" ]]; then codename="$(. "${PVE_OS_RELEASE_PATH}"; printf '%s' "${VERSION_CODENAME:-}")"; fi
  [[ "${codename}" == trixie ]] || { log.error "Debian Trixie is required; observed ${codename:-unknown}."; exit 1; }
  container="$(systemd-detect-virt --container 2>/dev/null || true)"
  [[ -z "${container}" || "${container}" == none ]] || { log.error "Containers are unsupported; observed ${container}."; exit 1; }
}

require.managed.accounts() {
  local user missing=0
  for user in root app agent proxmox; do
    if ! getent passwd "${user}" >/dev/null 2>&1; then log.error "Required account ${user} is missing."; missing=1; fi
  done
  (( missing == 0 )) || { log.error 'Run setup/pve/users.sh first.'; exit 1; }
}

require.shared.node() {
  [[ -s "${NODE_SHARED_NVM_DIR}/nvm.sh" ]] || { log.error "Shared Node is missing at ${NODE_SHARED_NVM_DIR}. Run setup/cli/node.sh first."; exit 1; }
  local resolved
  resolved="$(readlink -f /usr/local/bin/node 2>/dev/null || true)"
  [[ "${resolved}" == "${NODE_SHARED_NVM_DIR}"/* && "${resolved}" != /root/* ]] || { log.error "Shared Node symlink is missing or unsafe: ${resolved:-missing}."; exit 1; }
}

use.local.feature.files() {
  local script_dir repo_root ref
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/../.." && pwd)"
  [[ -r "${repo_root}/ansible/${FEATURE_PLAYBOOKS[0]}" && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]] || return 1
  for ref in "${FEATURE_SUPPORT_FILES[@]}"; do [[ -r "${repo_root}/ansible/${ref}" ]] || return 1; done
  PLAYBOOK_ROOT="${repo_root}/ansible"; GROUP_VARS_PATH="${PLAYBOOK_ROOT}/group_vars/${GROUP_VARS_FILE}"; CODEX_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${FEATURE_PLAYBOOKS[0]}"
}

fetch.feature.file() {
  local ref="$1" dest="${PLAYBOOK_ROOT}/$1"
  mkdir -p "$(dirname "${dest}")"; wget -qO "${dest}" "${PAGES_BASE_URL}/ansible/${ref}"
  [[ -s "${dest}" ]] || { log.error "Failed to fetch ansible/${ref}."; exit 1; }
}

prepare.feature.files() {
  local ref
  use.local.feature.files && return
  fetch.feature.file "group_vars/${GROUP_VARS_FILE}"
  for ref in "${FEATURE_PLAYBOOKS[@]}" "${FEATURE_SUPPORT_FILES[@]}"; do fetch.feature.file "${ref}"; done
}

write.extra.vars() {
  mkdir -p "${TMP_DIR}"
  cat > "${EXTRA_VARS_PATH}" <<EOF
---
ansible_python_interpreter_managed: "/usr/bin/python3"
codex_enable: true
codex_mode: $(yaml.quote "${FEATURE_MODE}")
codex_node_install_scope: "shared"
codex_node_shared_nvm_dir: $(yaml.quote "${NODE_SHARED_NVM_DIR}")
codex_nvm_dir: $(yaml.quote "${NODE_SHARED_NVM_DIR}")
codex_npm_package: $(yaml.quote "${CODEX_NPM_PACKAGE}")
codex_version: $(yaml.quote "${CODEX_VERSION}")
codex_binary_symlink: "/usr/local/bin/codex"
codex_install_docs_mcp: false
codex_runtime_facts_path: $(yaml.quote "${CODEX_FACTS_PATH}")
EOF
}

verify.managed.shells() {
  local user output resolved
  resolved="$(readlink -f /usr/local/bin/codex)"
  [[ "${resolved}" == "${NODE_SHARED_NVM_DIR}"/* && "${resolved}" != /root/* ]] || { log.error "Unsafe Codex target: ${resolved}."; exit 1; }
  for user in root app agent proxmox; do
    output="$(su -l "${user}" -c 'codex --version')" || { log.error "Codex verification failed for ${user}."; exit 1; }
    log "${user}: ${output}"
  done
}

run.preflight() {
  local user
  log "PVE 9/Trixie guard passed; shared NVM=${NODE_SHARED_NVM_DIR}; package=${CODEX_NPM_PACKAGE}@${CODEX_VERSION}."
  for user in root app agent proxmox; do getent passwd "${user}" >/dev/null 2>&1 && log "Account ${user}: present" || log "Account ${user}: missing"; done
  [[ -s "${NODE_SHARED_NVM_DIR}/nvm.sh" ]] && log 'Shared Node: present' || log 'Shared Node: missing; run setup/cli/node.sh first'
  command -v codex >/dev/null 2>&1 && log "Current Codex: $(codex --version)" || log 'Current Codex: missing'
}

main() {
  require.valid.mode
  source.release.common
  require.root
  require.apt
  require.pve9.trixie.host
  if [[ "${FEATURE_MODE}" == preflight ]]; then run.preflight; return; fi
  require.managed.accounts
  require.shared.node
  ensure.managed.ansible
  prepare.feature.files
  write.extra.vars
  ansible.runtime.run -i localhost, -c local -e "@${GROUP_VARS_PATH}" -e "@${EXTRA_VARS_PATH}" "${CODEX_PLAYBOOK_PATH}"
  verify.managed.shells
  [[ -s "${CODEX_FACTS_PATH}" ]] || { log.error "Expected facts file was not written: ${CODEX_FACTS_PATH}"; exit 1; }
  log 'Authenticate and configure Codex separately from each managed account.'
}

if [[ "${PROXMOX_RUNNER_SOURCE_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
