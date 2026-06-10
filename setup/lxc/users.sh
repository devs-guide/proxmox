#!/usr/bin/env bash
## Manual Proxmox LXC users feature runner.
## Local usage:
##   ./setup/lxc/users.sh [preflight|apply]
## Published usage:
##   wget -qO- https://devs-guide.github.io/proxmox/setup/lxc/users.sh | bash

set -euo pipefail

log()       { printf '[setup.lxc.users] %s\n' "$*" >&2; }
log.error() { printf '[setup.lxc.users][error] %s\n' "$*" >&2; }

TMP_DIR="/tmp/pve-feature-lxc-users"
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
  "debian/users.yml"
)
USERS_PLAYBOOK_REL="${FEATURE_PLAYBOOKS[0]}"
USERS_PLAYBOOK_URL="${PAGES_BASE_URL}/ansible/${USERS_PLAYBOOK_REL}"
USERS_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${USERS_PLAYBOOK_REL}"
LXC_USERS_EXTRA_VARS_PATH="${TMP_DIR}/lxc.users.extra-vars.yml"
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
FACTS_DIR="${PROXMOX_LXC_USERS_FACTS_DIR:-/etc/ansible/proxmox/facts}"
USERS_RUNTIME_FACTS_PATH="${PROXMOX_LXC_USERS_RUNTIME_FACTS_PATH:-${FACTS_DIR}/lxc.users.yml}"
FEATURE_MODE="${1:-${PROXMOX_LXC_USERS_MODE:-apply}}"
FEATURE_REQUIRE_CONTAINER="${PROXMOX_LXC_USERS_REQUIRE_CONTAINER:-1}"
FEATURE_ALLOW_HOST="${PROXMOX_LXC_USERS_ALLOW_HOST:-0}"
FEATURE_ASSUME_CONTAINER="${PROXMOX_LXC_USERS_ASSUME_CONTAINER:-0}"
FEATURE_DEFAULT_SUDO_GROUP="${PROXMOX_LXC_USERS_SUDO_GROUP:-sudo}"
FEATURE_DEFAULT_NONROOT_SUDO="${PROXMOX_LXC_USERS_NONROOT_SUDO:-1}"
FEATURE_PASSWORDLESS_SUDO="${PROXMOX_LXC_USERS_PASSWORDLESS_SUDO:-0}"
FEATURE_USER_UPDATE_PASSWORD="${PROXMOX_LXC_USERS_UPDATE_PASSWORD:-always}"
FEATURE_ROOT_PASSWORD="${PROXMOX_LXC_USERS_ROOT_PASSWORD:-root}"
FEATURE_APP_PASSWORD="${PROXMOX_LXC_USERS_APP_PASSWORD:-app}"
FEATURE_AGENT_PASSWORD="${PROXMOX_LXC_USERS_AGENT_PASSWORD:-agent}"
## Baseline policy:
## - Generic LXC common baseline: root, app, agent
## - No project-specific baseline in this runner; overrides must be explicit.
PROXMOX_LXC_USERS_BASELINE_USERS="${PROXMOX_LXC_USERS_BASELINE_USERS:-${PROXMOX_LXC_COMMON_BASELINE_USERS:-root app agent}}"
PROXMOX_LXC_USERS_MANAGED_USERS="${PROXMOX_LXC_USERS_MANAGED_USERS:-}"
PROXMOX_LXC_USERS_MANAGED_USERS_OVERRIDE="${PROXMOX_LXC_USERS_MANAGED_USERS_OVERRIDE:-false}"
if [[ -n "${PROXMOX_LXC_USERS_MANAGED_USERS:-}" ]]; then
  PROXMOX_LXC_USERS_MANAGED_USERS_OVERRIDE="true"
fi
USERS_SELF_URL="${PROXMOX_LXC_USERS_SELF_URL:-${PAGES_BASE_URL}/setup/lxc/users.sh}"
USERS_SUDO_REEXEC="${PROXMOX_LXC_USERS_SUDO_REEXEC:-0}"
CONTAINER_OS_PRETTY=""
declare -a PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS=()
declare -a PROXMOX_LXC_USERS_MANAGED_USERS_CLI=()

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
  # shellcheck source=/tmp/pve-feature-lxc-users/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

source.release.common

collect.sudo.env.args() {
  local -n _out="$1"

  _out=(
    "PROXMOX_LXC_USERS_MODE=${FEATURE_MODE}"
    "PROXMOX_LXC_USERS_REQUIRE_CONTAINER=${FEATURE_REQUIRE_CONTAINER}"
    "PROXMOX_LXC_USERS_ALLOW_HOST=${FEATURE_ALLOW_HOST}"
    "PROXMOX_LXC_USERS_ASSUME_CONTAINER=${FEATURE_ASSUME_CONTAINER}"
    "PROXMOX_LXC_USERS_SUDO_GROUP=${FEATURE_DEFAULT_SUDO_GROUP}"
    "PROXMOX_LXC_USERS_NONROOT_SUDO=${FEATURE_DEFAULT_NONROOT_SUDO}"
    "PROXMOX_LXC_USERS_PASSWORDLESS_SUDO=${FEATURE_PASSWORDLESS_SUDO}"
    "PROXMOX_LXC_USERS_UPDATE_PASSWORD=${FEATURE_USER_UPDATE_PASSWORD}"
    "PROXMOX_LXC_USERS_ROOT_PASSWORD=${FEATURE_ROOT_PASSWORD}"
    "PROXMOX_LXC_USERS_APP_PASSWORD=${FEATURE_APP_PASSWORD}"
    "PROXMOX_LXC_USERS_AGENT_PASSWORD=${FEATURE_AGENT_PASSWORD}"
    "PROXMOX_LXC_USERS_MANAGED_USERS_OVERRIDE=${PROXMOX_LXC_USERS_MANAGED_USERS_OVERRIDE}"
    "PROXMOX_LXC_USERS_FACTS_DIR=${FACTS_DIR}"
    "PROXMOX_LXC_USERS_RUNTIME_FACTS_PATH=${USERS_RUNTIME_FACTS_PATH}"
    "PROXMOX_LXC_USERS_SELF_URL=${USERS_SELF_URL}"
    "PROXMOX_LXC_USERS_SUDO_REEXEC=1"
    "PAGES_BASE_URL=${PAGES_BASE_URL}"
    "TMP_DIR=${TMP_DIR}"
  )

  if is.true "${PROXMOX_LXC_USERS_MANAGED_USERS_OVERRIDE}" && [[ -n "${PROXMOX_LXC_USERS_MANAGED_USERS:-}" ]]; then
    _out+=("PROXMOX_LXC_USERS_MANAGED_USERS=${PROXMOX_LXC_USERS_MANAGED_USERS}")
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

bool.yaml() {
  if is.true "${1:-false}"; then
    printf 'true'
  else
    printf 'false'
  fi
}

list.signature() {
  printf '%s\n' "$@" | awk 'NF {print}' | sort -u | tr '\n' ',' | sed 's/,$//'
}

user.password.for.name() {
  local user="${1:-}"
  case "${user}" in
    root) printf '%s\n' "${FEATURE_ROOT_PASSWORD}" ;;
    app) printf '%s\n' "${FEATURE_APP_PASSWORD}" ;;
    agent) printf '%s\n' "${FEATURE_AGENT_PASSWORD}" ;;
    *) printf '%s\n' "${user}" ;;
  esac
}

normalize.managed.users() {
  local user
  PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS=()
  if is.true "${PROXMOX_LXC_USERS_MANAGED_USERS_OVERRIDE}"; then
    read -r -a PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS <<< "${PROXMOX_LXC_USERS_MANAGED_USERS}"
  else
    for user in ${PROXMOX_LXC_USERS_BASELINE_USERS}; do
      [[ -n "${user}" ]] || continue
      PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS+=("${user}")
    done
  fi

  if ((${#PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[@]} == 0)); then
    read -r -a PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS <<< "${PROXMOX_LXC_USERS_BASELINE_USERS}"
  fi

  PROXMOX_LXC_USERS_MANAGED_USERS_CLI=()
  if is.true "${PROXMOX_LXC_USERS_MANAGED_USERS_OVERRIDE}"; then
    PROXMOX_LXC_USERS_MANAGED_USERS_CLI=("${PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[@]}")
  fi
}

assert.default.managed.users() {
  local baseline_signature
  local selected_signature

  if is.true "${PROXMOX_LXC_USERS_MANAGED_USERS_OVERRIDE}"; then
    return 0
  fi

  baseline_signature="$(list.signature ${PROXMOX_LXC_USERS_BASELINE_USERS})"
  selected_signature="$(list.signature "${PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[@]}")"

  if [[ "${selected_signature}" != "${baseline_signature}" ]]; then
    log.error "Unexpected managed user set. Baseline: ${PROXMOX_LXC_USERS_BASELINE_USERS}. Selected: ${PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[*]}"
    log.error "Set PROXMOX_LXC_USERS_MANAGED_USERS explicitly to override."
    exit 1
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
      log.error "This users feature must run inside a Debian LXC container, not on the Proxmox host."
      exit 1
    fi
  fi

  if is.true "${FEATURE_REQUIRE_CONTAINER}" && ((detected_container == 0)); then
    log.error "Container execution could not be confirmed. Re-run with PROXMOX_LXC_USERS_ASSUME_CONTAINER=1 only if you are already inside the LXC."
    exit 1
  fi
}

use.local.feature.files() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/../.." && pwd)"

  if [[ -r "${repo_root}/ansible/${USERS_PLAYBOOK_REL}" && -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]]; then
    PLAYBOOK_ROOT="${repo_root}/ansible"
    PLAYBOOK_GROUP_VARS_DIR="${PLAYBOOK_ROOT}/group_vars"
    GROUP_VARS_PATH="${PLAYBOOK_GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
    USERS_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${USERS_PLAYBOOK_REL}"
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
  fetch.feature.file "${USERS_PLAYBOOK_URL}" "${USERS_PLAYBOOK_PATH}"
}

run.feature.playbook() {
  local playbook_path="$1"
  shift
  "${ANSIBLE_VENV_BIN}" -i localhost, -c local -e "@${GROUP_VARS_PATH}" "$@" "${playbook_path}"
}

write.lxc.users.extra.vars.file() {
  mkdir -p "${TMP_DIR}"
  cat > "${LXC_USERS_EXTRA_VARS_PATH}" <<EOF
---
proxmox_feature_defaults:
  lxc_users:
    enabled: true
    mode: $(yaml.quote "${FEATURE_MODE}")
    require_container: $(bool.yaml "${FEATURE_REQUIRE_CONTAINER}")

proxmox_feature_facts_dir: $(yaml.quote "${FACTS_DIR}")

ansible_python_interpreter_managed: "/usr/bin/python3"

bootstrap_default_sudo_group: $(yaml.quote "${FEATURE_DEFAULT_SUDO_GROUP}")
bootstrap_default_nonroot_sudo: $(bool.yaml "${FEATURE_DEFAULT_NONROOT_SUDO}")
bootstrap_passwordless_sudo: $(bool.yaml "${FEATURE_PASSWORDLESS_SUDO}")
bootstrap_default_user_update_password: $(yaml.quote "${FEATURE_USER_UPDATE_PASSWORD}")
bootstrap_managed_users_require_sudo: $(bool.yaml "${FEATURE_DEFAULT_NONROOT_SUDO}")

user_defs:
$(if ((${#PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[@]} > 0)); then
  for user in "${PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[@]}"; do
    printf '  - name: %s\n    password: %s\n    shell: "/bin/bash"\n' \
      "$(yaml.quote "${user}")" \
      "$(yaml.quote "$(user.password.for.name "${user}")")"
  done
else
  printf '  - name: %s\n    password: %s\n    shell: "/bin/bash"\n' "$(yaml.quote "root")" "$(yaml.quote "${FEATURE_ROOT_PASSWORD}")"
  printf '  - name: %s\n    password: %s\n    shell: "/bin/bash"\n' "$(yaml.quote "app")" "$(yaml.quote "${FEATURE_APP_PASSWORD}")"
  printf '  - name: %s\n    password: %s\n    shell: "/bin/bash"\n' "$(yaml.quote "agent")" "$(yaml.quote "${FEATURE_AGENT_PASSWORD}")"
fi)
proxmox_lxc_users_managed_users_runner:
$(if ((${#PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[@]} > 0)); then
  for user in "${PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[@]}"; do
    printf '  - %s\n' "$(yaml.quote "${user}")"
  done
else
  for user in ${PROXMOX_LXC_USERS_BASELINE_USERS}; do
    printf '  - %s\n' "$(yaml.quote "${user}")"
  done
fi)
proxmox_lxc_users_managed_users_cli:
$(if is.true "${PROXMOX_LXC_USERS_MANAGED_USERS_OVERRIDE}"; then
  for user in "${PROXMOX_LXC_USERS_MANAGED_USERS_CLI[@]}"; do
    printf '  - %s\n' "$(yaml.quote "${user}")"
  done
else
  printf '  -\n'
fi)
proxmox_lxc_users_managed_users_override: $(bool.yaml "${PROXMOX_LXC_USERS_MANAGED_USERS_OVERRIDE}")
EOF
  log "Prepared LXC users extra-vars: ${LXC_USERS_EXTRA_VARS_PATH}"
}

run.preflight() {
  local user passwd_entry shell home groups
  normalize.managed.users
  assert.default.managed.users
  log "Container OS: ${CONTAINER_OS_PRETTY}"
  log "Managed users: ${PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[*]}"
  log "Default password policy: ${PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[*]} (override with PROXMOX_LXC_USERS_*_PASSWORD)."
  for user in "${PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[@]}"; do
    passwd_entry="$(getent passwd "${user}" || true)"
    if [[ -n "${passwd_entry}" ]]; then
      shell="$(printf '%s' "${passwd_entry}" | awk -F: '{print $7}')"
      home="$(printf '%s' "${passwd_entry}" | awk -F: '{print $6}')"
      groups="$(id -nG "${user}" 2>/dev/null || true)"
      log "user=${user} present shell=${shell} home=${home} groups=${groups}"
    else
      log "user=${user} missing"
    fi
  done
  log "Apply command:"
  log "  wget -qO- ${PAGES_BASE_URL}/setup/lxc/users.sh | bash"
}

verify.managed.users() {
  local user groups
  for user in "${PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[@]}"; do
    if ! getent passwd "${user}" >/dev/null; then
      log.error "Managed user missing after apply: ${user}"
      exit 1
    fi
    if [[ "${user}" != "root" ]] && is.true "${FEATURE_DEFAULT_NONROOT_SUDO}"; then
      groups="$(id -nG "${user}" 2>/dev/null || true)"
      if ! printf '%s\n' "${groups}" | tr ' ' '\n' | grep -qx "${FEATURE_DEFAULT_SUDO_GROUP}"; then
        log.error "Managed user ${user} is missing sudo group ${FEATURE_DEFAULT_SUDO_GROUP}"
        exit 1
      fi
    fi
  done
}

write.lxc.users.runtime.facts() {
  local user passwd_entry home shell groups group
  mkdir -p "${FACTS_DIR}"
  {
    printf '%s\n' '---'
    printf '%s\n' 'proxmox_lxc_users_runtime:'
    printf '  mode: %s\n' "$(yaml.quote "${FEATURE_MODE}")"
    printf '  sudo_group: %s\n' "$(yaml.quote "${FEATURE_DEFAULT_SUDO_GROUP}")"
    printf '%s\n' '  users:'
    for user in "${PROXMOX_LXC_USERS_SELECTED_MANAGED_USERS[@]}"; do
      passwd_entry="$(getent passwd "${user}")"
      home="$(printf '%s' "${passwd_entry}" | awk -F: '{print $6}')"
      shell="$(printf '%s' "${passwd_entry}" | awk -F: '{print $7}')"
      printf '    - name: %s\n' "$(yaml.quote "${user}")"
      printf '      present: true\n'
      printf '      home: %s\n' "$(yaml.quote "${home}")"
      printf '      shell: %s\n' "$(yaml.quote "${shell}")"
      printf '%s\n' '      groups:'
      groups="$(id -nG "${user}" 2>/dev/null || true)"
      for group in ${groups}; do
        printf '        - %s\n' "$(yaml.quote "${group}")"
      done
    done
  } > "${USERS_RUNTIME_FACTS_PATH}"
  log "Wrote LXC users runtime facts: ${USERS_RUNTIME_FACTS_PATH}"
}

run.lxc.users.feature() {
  normalize.managed.users
  assert.default.managed.users
  write.lxc.users.extra.vars.file
  log "Running Debian users feature in mode=${FEATURE_MODE}..."
  run.feature.playbook "${USERS_PLAYBOOK_PATH}" -e "@${LXC_USERS_EXTRA_VARS_PATH}"
  verify.managed.users
  write.lxc.users.runtime.facts
}

main() {
  ensure.root.or.sudo.reexec "${USERS_SUDO_REEXEC}" "${USERS_SELF_URL}" "$@"
  require.root
  require.apt
  require.valid.mode
  require.debian.container
  require.container.not.host

  if [[ "${FEATURE_MODE}" == "preflight" ]]; then
    run.preflight
    exit 0
  fi

  ensure.container.ansible
  prepare.feature.files
  run.lxc.users.feature
}

main "$@"
