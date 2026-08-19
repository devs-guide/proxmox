#!/usr/bin/env bash
# Shared managed-Ansible runtime resolution and invocation contract.

: "${PROXMOX_ANSIBLE_VENV:=${ANSIBLE_VENV:-/opt/ansible-venv}}"
: "${PROXMOX_ANSIBLE_CORE_VERSION:=${ANSIBLE_CORE_VERSION:-2.20.5}}"

ANSIBLE_VENV="${PROXMOX_ANSIBLE_VENV}"
ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
ANSIBLE_RUNTIME_PYTHON="${ANSIBLE_VENV}/bin/python"
ANSIBLE_CORE_VERSION="${PROXMOX_ANSIBLE_CORE_VERSION}"
ANSIBLE_CORE_SPEC="ansible-core==${ANSIBLE_CORE_VERSION}"
ANSIBLE_PLAYBOOK_BIN=""

ansible.runtime.error() {
  if declare -F log.error >/dev/null 2>&1; then
    log.error "$*"
  else
    printf '[ansible.runtime][error] %s\n' "$*" >&2
  fi
}

ansible.runtime.version.line.matches.policy() {
  local version_line="${1:-}"
  [[ "${version_line}" == "ansible-playbook [core ${ANSIBLE_CORE_VERSION}]" ]]
}

ansible.runtime.require() {
  local version_output="" version_line=""

  case "${ANSIBLE_VENV_BIN}" in
    /*) ;;
    *)
      ansible.runtime.error "managed ansible-playbook path must be absolute: ${ANSIBLE_VENV_BIN}"
      return 10
      ;;
  esac
  if [[ ! -x "${ANSIBLE_VENV_BIN}" ]]; then
    ansible.runtime.error "managed ansible-playbook is missing or not executable: ${ANSIBLE_VENV_BIN}"
    ansible.runtime.error "repair it with the matching Proxmox release bootstrap before retrying"
    return 10
  fi
  if ! version_output="$("${ANSIBLE_VENV_BIN}" --version 2>/dev/null)"; then
    ansible.runtime.error "managed ansible-playbook failed its version probe: ${ANSIBLE_VENV_BIN}"
    return 10
  fi
  version_line="${version_output%%$'\n'*}"
  if ! ansible.runtime.version.line.matches.policy "${version_line}"; then
    ansible.runtime.error "managed ansible-playbook is outside policy: ${version_line:-<empty>}"
    ansible.runtime.error "expected: ansible-playbook [core ${ANSIBLE_CORE_VERSION}]"
    return 10
  fi
  if [[ ! -x "${ANSIBLE_RUNTIME_PYTHON}" ]]; then
    ansible.runtime.error "managed Ansible Python is missing or not executable: ${ANSIBLE_RUNTIME_PYTHON}"
    return 10
  fi
  ANSIBLE_PLAYBOOK_BIN="${ANSIBLE_VENV_BIN}"
  export ANSIBLE_PLAYBOOK_BIN ANSIBLE_RUNTIME_PYTHON
}

ansible.runtime.run() {
  ansible.runtime.require || return $?
  "${ANSIBLE_PLAYBOOK_BIN}" \
    -e "ansible_python_interpreter=${ANSIBLE_RUNTIME_PYTHON}" \
    "$@"
}
