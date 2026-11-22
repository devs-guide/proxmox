#!/usr/bin/env bash
## PVE 9 shared Node.js setup.
##   wget -qO- https://devs-guide.github.io/proxmox/setup/cli/node.sh | bash
##   wget -qO- https://devs-guide.github.io/proxmox/setup/cli/node.sh | bash -s -- upgrade

set -euo pipefail

log() { printf '[setup.cli.node] %s\n' "$*" >&2; }
log.error() { printf '[setup.cli.node][error] %s\n' "$*" >&2; }

TMP_DIR="${TMP_DIR:-/tmp/pve-feature-cli-node}"
PAGES_BASE_URL="${PAGES_BASE_URL:-https://devs-guide.github.io/proxmox}"
PLAYBOOK_ROOT="${TMP_DIR}/ansible"
LOCAL_COMMON_HELPER="../../bootstrap/release.common.sh"
COMMON_HELPER_PATH="${TMP_DIR}/release.common.sh"
GROUP_VARS_FILE="proxmox.yml"
GROUP_VARS_PATH="${PLAYBOOK_ROOT}/group_vars/${GROUP_VARS_FILE}"
FEATURE_PLAYBOOKS=("proxmox/cli/node.yml")
FEATURE_SUPPORT_FILES=("proxmox/pve/guard.yml" "debian/node.yml")
NODE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${FEATURE_PLAYBOOKS[0]}"
EXTRA_VARS_PATH="${TMP_DIR}/cli.node.extra-vars.yml"
if [[ "${PROXMOX_RUNNER_SOURCE_ONLY:-0}" == 1 ]]; then
  FEATURE_MODE="${PROXMOX_CLI_NODE_MODE:-apply}"
else
  FEATURE_MODE="${1:-${PROXMOX_CLI_NODE_MODE:-apply}}"
fi
NODE_VERSION="${PROXMOX_CLI_NODE_VERSION:-lts/*}"
NODE_NVM_VERSION="${PROXMOX_CLI_NODE_NVM_VERSION:-v0.40.4}"
NODE_SHARED_NVM_DIR="${PROXMOX_CLI_NODE_SHARED_NVM_DIR:-/usr/local/lib/nvm}"
NODE_NPM_POLICY="${PROXMOX_CLI_NODE_NPM_POLICY:-bundled}"
NODE_NPM_VERSION="${PROXMOX_CLI_NODE_NPM_VERSION:-}"
NODE_GLOBAL_PACKAGES="${PROXMOX_CLI_NODE_GLOBAL_PACKAGES:-}"
NODE_ENABLE_COREPACK="${PROXMOX_CLI_NODE_ENABLE_COREPACK:-0}"
NODE_FACTS_PATH="${PROXMOX_CLI_NODE_FACTS_PATH:-/etc/ansible/proxmox/facts/cli.node.yml}"
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
  # shellcheck source=/tmp/pve-feature-cli-node/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

is.true() { case "${1:-}" in 1|true|yes|y|on) return 0 ;; *) return 1 ;; esac; }
yaml.quote() { local value="${1:-}"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; printf '"%s"' "${value}"; }
bool.yaml() { if is.true "${1:-}"; then printf true; else printf false; fi; }
yaml.string.list() {
  local raw="${1:-}" item first=1
  local -a values=()
  read -r -a values <<< "${raw}"
  if ((${#values[@]} == 0)); then printf '[]'; return; fi
  printf '['
  for item in "${values[@]}"; do (( first )) || printf ', '; first=0; yaml.quote "${item}"; done
  printf ']'
}

require.valid.inputs() {
  case "${FEATURE_MODE}" in preflight|apply|upgrade) ;; *) log.error "Unsupported mode: ${FEATURE_MODE}."; exit 1 ;; esac
  case "${NODE_NPM_POLICY}" in bundled|pinned|latest) ;; *) log.error "Unsupported npm policy: ${NODE_NPM_POLICY}."; exit 1 ;; esac
  [[ "${NODE_NPM_POLICY}" != pinned || -n "${NODE_NPM_VERSION}" ]] || { log.error 'Pinned npm policy requires PROXMOX_CLI_NODE_NPM_VERSION.'; exit 1; }
}

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

use.local.feature.files() {
  local script_dir repo_root ref
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/../.." && pwd)"
  [[ -r "${repo_root}/ansible/${FEATURE_PLAYBOOKS[0]}" && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]] || return 1
  for ref in "${FEATURE_SUPPORT_FILES[@]}"; do [[ -r "${repo_root}/ansible/${ref}" ]] || return 1; done
  PLAYBOOK_ROOT="${repo_root}/ansible"; GROUP_VARS_PATH="${PLAYBOOK_ROOT}/group_vars/${GROUP_VARS_FILE}"; NODE_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${FEATURE_PLAYBOOKS[0]}"
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
  local install_policy=if_missing_or_too_old
  [[ "${FEATURE_MODE}" == upgrade ]] && install_policy=always
  mkdir -p "${TMP_DIR}"
  cat > "${EXTRA_VARS_PATH}" <<EOF
---
ansible_python_interpreter_managed: "/usr/bin/python3"
node_enable: true
node_mode: $(yaml.quote "${FEATURE_MODE}")
node_nvm_version: $(yaml.quote "${NODE_NVM_VERSION}")
nvm_version: $(yaml.quote "${NODE_NVM_VERSION}")
node_install_scope: "shared"
node_shared_nvm_dir: $(yaml.quote "${NODE_SHARED_NVM_DIR}")
node_nvm_dir: $(yaml.quote "${NODE_SHARED_NVM_DIR}")
nvm_dir: $(yaml.quote "${NODE_SHARED_NVM_DIR}")
node_version: $(yaml.quote "${NODE_VERSION}")
node_install_policy: $(yaml.quote "${install_policy}")
node_npm_policy: $(yaml.quote "${NODE_NPM_POLICY}")
node_npm_version: $(yaml.quote "${NODE_NPM_VERSION}")
node_global_packages: $(yaml.string.list "${NODE_GLOBAL_PACKAGES}")
node_create_system_symlinks: true
node_enable_corepack: $(bool.yaml "${NODE_ENABLE_COREPACK}")
node_runtime_facts_path: $(yaml.quote "${NODE_FACTS_PATH}")
EOF
}

verify.managed.shells() {
  local user output
  for user in root app agent proxmox; do
    output="$(su -l "${user}" -c 'node --version && npm --version && npx --version')" || { log.error "Node verification failed for ${user}."; exit 1; }
    log "${user}: ${output//$'\n'/, }"
  done
  for command_name in node npm npx; do
    local resolved
    resolved="$(readlink -f "/usr/local/bin/${command_name}")"
    [[ "${resolved}" == "${NODE_SHARED_NVM_DIR}"/* && "${resolved}" != /root/* ]] || { log.error "Unsafe ${command_name} target: ${resolved}"; exit 1; }
  done
}

run.preflight() {
  local user
  log "PVE 9/Trixie guard passed; mode=${FEATURE_MODE}; nvm=${NODE_NVM_VERSION}; node=${NODE_VERSION}; scope=${NODE_SHARED_NVM_DIR}."
  for user in root app agent proxmox; do getent passwd "${user}" >/dev/null 2>&1 && log "Account ${user}: present" || log "Account ${user}: missing"; done
  command -v node >/dev/null 2>&1 && log "Current node: $(node --version)" || log 'Current node: missing'
}

main() {
  require.valid.inputs
  source.release.common
  require.root
  require.apt
  require.pve9.trixie.host
  if [[ "${FEATURE_MODE}" == preflight ]]; then run.preflight; return; fi
  require.managed.accounts
  ensure.managed.ansible
  prepare.feature.files
  write.extra.vars
  ansible.runtime.run -i localhost, -c local -e "@${GROUP_VARS_PATH}" -e "@${EXTRA_VARS_PATH}" "${NODE_PLAYBOOK_PATH}"
  verify.managed.shells
  [[ -s "${NODE_FACTS_PATH}" ]] || { log.error "Expected facts file was not written: ${NODE_FACTS_PATH}"; exit 1; }
}

if [[ "${PROXMOX_RUNNER_SOURCE_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
