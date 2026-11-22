#!/usr/bin/env bash
## PVE 9 managed-account convergence.
##   wget -qO- https://devs-guide.github.io/proxmox/setup/pve/users.sh | bash
##   wget -qO- https://devs-guide.github.io/proxmox/setup/pve/users.sh | bash -s -- preflight

set -euo pipefail

log() { printf '[setup.pve.users] %s\n' "$*" >&2; }
log.error() { printf '[setup.pve.users][error] %s\n' "$*" >&2; }

TMP_DIR="${TMP_DIR:-/tmp/pve-feature-users}"
PAGES_BASE_URL="${PAGES_BASE_URL:-https://devs-guide.github.io/proxmox}"
PLAYBOOK_ROOT="${TMP_DIR}/ansible"
LOCAL_COMMON_HELPER="../../bootstrap/release.common.sh"
COMMON_HELPER_PATH="${TMP_DIR}/release.common.sh"
GROUP_VARS_FILE="proxmox.yml"
GROUP_VARS_PATH="${PLAYBOOK_ROOT}/group_vars/${GROUP_VARS_FILE}"
FEATURE_PLAYBOOKS=("proxmox/pve/users.yml")
FEATURE_SUPPORT_FILES=("proxmox/pve/guard.yml" "debian/users.yml")
USERS_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${FEATURE_PLAYBOOKS[0]}"
EXTRA_VARS_PATH="${TMP_DIR}/pve.users.extra-vars.yml"
if [[ "${PROXMOX_RUNNER_SOURCE_ONLY:-0}" == 1 ]]; then
  FEATURE_MODE="${PROXMOX_PVE_USERS_MODE:-apply}"
else
  FEATURE_MODE="${1:-${PROXMOX_PVE_USERS_MODE:-apply}}"
fi
FACTS_PATH="${PROXMOX_PVE_USERS_FACTS_PATH:-/etc/ansible/proxmox/facts/pve.users.yml}"
PROXMOX_RUNTIME_CONTEXT="host"
PVE_OS_RELEASE_PATH="${PROXMOX_TEST_OS_RELEASE_PATH:-/etc/os-release}"

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
  wget -qO "${COMMON_HELPER_PATH}" "${PAGES_BASE_URL}/release.common.sh"
  [[ -s "${COMMON_HELPER_PATH}" ]] || { log.error 'Downloaded release.common.sh is empty.'; exit 1; }
  # shellcheck source=/tmp/pve-feature-users/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

require.valid.mode() {
  case "${FEATURE_MODE}" in
    preflight|apply) ;;
    *) log.error "Unsupported mode: ${FEATURE_MODE}. Use preflight or apply."; exit 1 ;;
  esac
}

require.pve9.trixie.host() {
  local version="" codename="" container=""
  command -v pveversion >/dev/null 2>&1 || { log.error 'This runner requires Proxmox VE.'; exit 1; }
  version="$(pveversion 2>/dev/null || true)"
  [[ "${version}" == pve-manager/9.* ]] || { log.error "PVE 9 is required; observed ${version:-unknown}."; exit 1; }
  if [[ -r "${PVE_OS_RELEASE_PATH}" ]]; then
    codename="$(. "${PVE_OS_RELEASE_PATH}"; printf '%s' "${VERSION_CODENAME:-}")"
  fi
  [[ "${codename}" == trixie ]] || { log.error "Debian Trixie is required; observed ${codename:-unknown}."; exit 1; }
  container="$(systemd-detect-virt --container 2>/dev/null || true)"
  [[ -z "${container}" || "${container}" == none ]] || { log.error "Containers are unsupported; observed ${container}."; exit 1; }
}

use.local.feature.files() {
  local script_dir repo_root ref
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/../.." && pwd)"
  [[ -r "${repo_root}/ansible/${FEATURE_PLAYBOOKS[0]}" && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]] || return 1
  for ref in "${FEATURE_SUPPORT_FILES[@]}"; do [[ -r "${repo_root}/ansible/${ref}" ]] || return 1; done
  PLAYBOOK_ROOT="${repo_root}/ansible"
  GROUP_VARS_PATH="${PLAYBOOK_ROOT}/group_vars/${GROUP_VARS_FILE}"
  USERS_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${FEATURE_PLAYBOOKS[0]}"
  return 0
}

fetch.feature.file() {
  local ref="$1" dest="${PLAYBOOK_ROOT}/$1"
  mkdir -p "$(dirname "${dest}")"
  wget -qO "${dest}" "${PAGES_BASE_URL}/ansible/${ref}"
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
bootstrap_default_password_mode: "username"
bootstrap_default_user_update_password: "always"
bootstrap_default_nonroot_sudo: true
bootstrap_managed_users_require_sudo: true
bootstrap_passwordless_sudo: false
user_defs:
  - name: "root"
  - name: "app"
  - name: "agent"
  - name: "proxmox"
pve_users_runtime_facts_path: "${FACTS_PATH}"
EOF
}

run.preflight() {
  local user
  log 'PVE 9/Trixie host guard passed.'
  for user in root app agent proxmox; do
    if getent passwd "${user}" >/dev/null 2>&1; then log "Account ${user}: present"; else log "Account ${user}: missing (will be created)"; fi
  done
  log "Facts path: ${FACTS_PATH}"
}

main() {
  require.valid.mode
  source.release.common
  require.root
  require.apt
  require.pve9.trixie.host
  if [[ "${FEATURE_MODE}" == preflight ]]; then run.preflight; return; fi
  ensure.managed.ansible
  prepare.feature.files
  write.extra.vars
  ansible.runtime.run -i localhost, -c local -e "@${GROUP_VARS_PATH}" -e "@${EXTRA_VARS_PATH}" "${USERS_PLAYBOOK_PATH}"
  [[ -s "${FACTS_PATH}" ]] || { log.error "Expected facts file was not written: ${FACTS_PATH}"; exit 1; }
  log 'Managed PVE accounts converged.'
}

if [[ "${PROXMOX_RUNNER_SOURCE_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
