#!/usr/bin/env bash
# Shared platform detection, managed-Ansible resolution, and invocation contract.
# Source this file from runners, or inspect a host without changing it:
#   bash ansible.runtime.sh check --context auto --format human
# Exit status: 0 ready, 10 bootstrap required, 20 unsupported/mismatched host.

: "${PROXMOX_ANSIBLE_VENV:=${ANSIBLE_VENV:-/opt/ansible-venv}}"
: "${PROXMOX_ANSIBLE_CORE_VERSION:=${ANSIBLE_CORE_VERSION:-${PROXMOX_BOOTSTRAP_ANSIBLE_CORE_VERSION:-2.20.5}}}"
: "${PROXMOX_RUNTIME_CONTEXT:=auto}"
: "${PROXMOX_RUNTIME_PYTHON_MIN_MAJOR:=3}"
: "${PROXMOX_RUNTIME_PYTHON_MIN_MINOR:=12}"

ANSIBLE_VENV="${PROXMOX_ANSIBLE_VENV}"
ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
ANSIBLE_RUNTIME_PYTHON="${ANSIBLE_VENV}/bin/python"
ANSIBLE_CORE_VERSION="${PROXMOX_ANSIBLE_CORE_VERSION}"
ANSIBLE_CORE_SPEC="ansible-core==${ANSIBLE_CORE_VERSION}"
ANSIBLE_PLAYBOOK_BIN=""

ANSIBLE_RUNTIME_PREPARED=0
ANSIBLE_RUNTIME_CONTEXT="unknown"
ANSIBLE_RUNTIME_SUPPORTED=1
ANSIBLE_RUNTIME_ERROR=""
ANSIBLE_RUNTIME_PVE_PRESENT=0
ANSIBLE_RUNTIME_PVE_VERSION=""
ANSIBLE_RUNTIME_PVE_MAJOR=""
ANSIBLE_RUNTIME_DEBIAN_ID=""
ANSIBLE_RUNTIME_DEBIAN_VERSION=""
ANSIBLE_RUNTIME_DEBIAN_CODENAME=""
ANSIBLE_RUNTIME_SYSTEM_PYTHON=""
ANSIBLE_RUNTIME_SYSTEM_PYTHON_VERSION=""
ANSIBLE_RUNTIME_SYSTEM_PYTHON_COMPATIBLE=0
ANSIBLE_RUNTIME_SYSTEM_VENV_READY=0
ANSIBLE_RUNTIME_MANAGED_PYTHON=""
ANSIBLE_RUNTIME_MANAGED_PYTHON_VERSION=""
ANSIBLE_RUNTIME_MANAGED_PYTHON_READY=0
ANSIBLE_RUNTIME_SOURCE_PYTHON=""
ANSIBLE_RUNTIME_SOURCE_PYTHON_VERSION=""
ANSIBLE_RUNTIME_SOURCE_PYTHON_READY=0
ANSIBLE_RUNTIME_ANSIBLE_READY=0
ANSIBLE_RUNTIME_ANSIBLE_VERSION=""
ANSIBLE_RUNTIME_ANSIBLE_ACTION="create"
ANSIBLE_RUNTIME_PYTHON_STRATEGY="source_build"
ANSIBLE_RUNTIME_BOOTSTRAP_PYTHON=""
ANSIBLE_RUNTIME_TARGET_PYTHON=""
ANSIBLE_RUNTIME_INSTALL_VENV_SUPPORT=0
ANSIBLE_RUNTIME_BUILD_PYTHON=1
ANSIBLE_RUNTIME_FALLBACK_VERSION=""
ANSIBLE_RUNTIME_FALLBACK_MAJOR_MINOR=""
ANSIBLE_RUNTIME_VARS_PATH="${PROXMOX_RUNTIME_VARS_PATH:-}"

ansible.runtime.error() {
  if declare -F log.error >/dev/null 2>&1; then
    log.error "$*"
  else
    printf '[ansible.runtime][error] %s\n' "$*" >&2
  fi
}

ansible.runtime.log() {
  if declare -F log >/dev/null 2>&1; then
    log "$*"
  else
    printf '[ansible.runtime] %s\n' "$*" >&2
  fi
}

ansible.runtime.version.line.matches.policy() {
  local version_line="${1:-}"
  [[ "${version_line}" == "ansible-playbook [core ${ANSIBLE_CORE_VERSION}]" ]]
}

ansible.runtime.python.version() {
  local python_bin="${1:-}"
  [[ -n "${python_bin}" && -x "${python_bin}" ]] || return 1
  "${python_bin}" -E -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null
}

ansible.runtime.python.compatible() {
  local python_bin="${1:-}"
  [[ -n "${python_bin}" && -x "${python_bin}" ]] || return 1
  "${python_bin}" -E - \
    "${PROXMOX_RUNTIME_PYTHON_MIN_MAJOR}" \
    "${PROXMOX_RUNTIME_PYTHON_MIN_MINOR}" <<'PY' >/dev/null 2>&1
import sys

minimum = (int(sys.argv[1]), int(sys.argv[2]))
raise SystemExit(0 if sys.version_info[:2] >= minimum else 1)
PY
}

ansible.runtime.os.value() {
  local key="${1:-}"
  local os_release="${PROXMOX_RUNTIME_OS_RELEASE_PATH:-/etc/os-release}"
  [[ -r "${os_release}" ]] || return 1
  sed -n "s/^${key}=//p" "${os_release}" 2>/dev/null \
    | head -n1 \
    | sed -e 's/^"//' -e 's/"$//'
}

ansible.runtime.detect.container() {
  if [[ -n "${PROXMOX_RUNTIME_CONTAINER:-}" ]]; then
    [[ "${PROXMOX_RUNTIME_CONTAINER}" == "1" ]]
    return
  fi
  [[ -f /.dockerenv || -f /run/.containerenv || -f /run/systemd/container ]] && return 0
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    systemd-detect-virt --quiet --container >/dev/null 2>&1
    return
  fi
  return 1
}

ansible.runtime.detect.platform() {
  local requested_context="${1:-${PROXMOX_RUNTIME_CONTEXT:-auto}}"
  local pve_output="" expected_pve_codename=""

  ANSIBLE_RUNTIME_SUPPORTED=1
  ANSIBLE_RUNTIME_ERROR=""
  ANSIBLE_RUNTIME_PVE_PRESENT=0
  ANSIBLE_RUNTIME_PVE_VERSION=""
  ANSIBLE_RUNTIME_PVE_MAJOR=""

  ANSIBLE_RUNTIME_DEBIAN_ID="$(ansible.runtime.os.value ID || true)"
  ANSIBLE_RUNTIME_DEBIAN_VERSION="$(ansible.runtime.os.value VERSION_ID || true)"
  ANSIBLE_RUNTIME_DEBIAN_CODENAME="$(ansible.runtime.os.value VERSION_CODENAME || true)"

  if command -v pveversion >/dev/null 2>&1; then
    pve_output="$(pveversion 2>/dev/null | head -n1 || true)"
    if [[ "${pve_output}" =~ ^pve-manager/([0-9]+(\.[0-9]+)*)/ ]]; then
      ANSIBLE_RUNTIME_PVE_PRESENT=1
      ANSIBLE_RUNTIME_PVE_VERSION="${BASH_REMATCH[1]}"
      ANSIBLE_RUNTIME_PVE_MAJOR="${ANSIBLE_RUNTIME_PVE_VERSION%%.*}"
    fi
  fi

  case "${requested_context}" in
    auto)
      if ((ANSIBLE_RUNTIME_PVE_PRESENT)); then
        ANSIBLE_RUNTIME_CONTEXT="pve_host"
      elif ansible.runtime.detect.container; then
        ANSIBLE_RUNTIME_CONTEXT="debian_container"
      else
        ANSIBLE_RUNTIME_CONTEXT="debian_host"
      fi
      ;;
    host)
      if ((ANSIBLE_RUNTIME_PVE_PRESENT)); then
        ANSIBLE_RUNTIME_CONTEXT="pve_host"
      else
        ANSIBLE_RUNTIME_CONTEXT="debian_host"
      fi
      ;;
    container)
      ANSIBLE_RUNTIME_CONTEXT="debian_container"
      ;;
    *)
      ANSIBLE_RUNTIME_SUPPORTED=0
      ANSIBLE_RUNTIME_ERROR="unsupported runtime context: ${requested_context}"
      ANSIBLE_RUNTIME_CONTEXT="unknown"
      ;;
  esac

  if ((ANSIBLE_RUNTIME_PVE_PRESENT)); then
    case "${ANSIBLE_RUNTIME_PVE_MAJOR}" in
      6) expected_pve_codename="buster" ;;
      7) expected_pve_codename="bullseye" ;;
      8) expected_pve_codename="bookworm" ;;
      9) expected_pve_codename="trixie" ;;
    esac
    if [[ -n "${expected_pve_codename}" \
          && "${ANSIBLE_RUNTIME_DEBIAN_CODENAME}" != "${expected_pve_codename}" ]]; then
      ANSIBLE_RUNTIME_SUPPORTED=0
      ANSIBLE_RUNTIME_ERROR="PVE ${ANSIBLE_RUNTIME_PVE_MAJOR}.x requires Debian ${expected_pve_codename}; found ${ANSIBLE_RUNTIME_DEBIAN_CODENAME:-unknown}"
    fi
  fi

  if [[ -n "${PROXMOX_RUNTIME_EXPECT_PVE_MAJOR:-}" ]]; then
    if ((ANSIBLE_RUNTIME_PVE_PRESENT == 0)); then
      ANSIBLE_RUNTIME_SUPPORTED=0
      ANSIBLE_RUNTIME_ERROR="expected PVE ${PROXMOX_RUNTIME_EXPECT_PVE_MAJOR}.x, but pveversion was unavailable"
    elif [[ "${ANSIBLE_RUNTIME_PVE_MAJOR}" != "${PROXMOX_RUNTIME_EXPECT_PVE_MAJOR}" ]]; then
      ANSIBLE_RUNTIME_SUPPORTED=0
      ANSIBLE_RUNTIME_ERROR="expected PVE ${PROXMOX_RUNTIME_EXPECT_PVE_MAJOR}.x, found ${ANSIBLE_RUNTIME_PVE_VERSION}"
    fi
  fi
  if [[ -n "${PROXMOX_RUNTIME_EXPECT_DEBIAN_CODENAME:-}" \
        && "${ANSIBLE_RUNTIME_DEBIAN_CODENAME}" != "${PROXMOX_RUNTIME_EXPECT_DEBIAN_CODENAME}" ]]; then
    ANSIBLE_RUNTIME_SUPPORTED=0
    ANSIBLE_RUNTIME_ERROR="expected Debian ${PROXMOX_RUNTIME_EXPECT_DEBIAN_CODENAME}, found ${ANSIBLE_RUNTIME_DEBIAN_CODENAME:-unknown}"
  fi
}

ansible.runtime.select.fallback() {
  if [[ -n "${PROXMOX_BOOTSTRAP_PYTHON_VERSION:-}" ]]; then
    ANSIBLE_RUNTIME_FALLBACK_VERSION="${PROXMOX_BOOTSTRAP_PYTHON_VERSION}"
  elif [[ "${ANSIBLE_RUNTIME_PVE_MAJOR}" == "9" \
          || "${ANSIBLE_RUNTIME_DEBIAN_CODENAME}" == "trixie" \
          || "${ANSIBLE_RUNTIME_DEBIAN_VERSION%%.*}" == "13" ]]; then
    ANSIBLE_RUNTIME_FALLBACK_VERSION="3.13.5"
  else
    ANSIBLE_RUNTIME_FALLBACK_VERSION="3.12.3"
  fi
  ANSIBLE_RUNTIME_FALLBACK_MAJOR_MINOR="${ANSIBLE_RUNTIME_FALLBACK_VERSION%.*}"

  PYTHON_VERSION="${ANSIBLE_RUNTIME_FALLBACK_VERSION}"
  PYTHON_MAJOR_MINOR="${ANSIBLE_RUNTIME_FALLBACK_MAJOR_MINOR}"
  PYTHON_SOURCE_PREFIX="${PROXMOX_BOOTSTRAP_PYTHON_SOURCE_PREFIX:-/usr/local}"
  PYTHON_BIN="${PYTHON_SOURCE_PREFIX}/bin/python${PYTHON_MAJOR_MINOR}"
  PYTHON_SRC_DIR="${PYTHON_SOURCE_PREFIX}/src/Python-${PYTHON_VERSION}"
  PYTHON_SRC_ARCHIVE="${PYTHON_SRC_DIR}.tgz"
  PYTHON_SRC_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"
  MANAGED_TARGET_PYTHON_HOME="${PROXMOX_BOOTSTRAP_MANAGED_TARGET_PYTHON_HOME:-/opt/ansible/py${PYTHON_MAJOR_MINOR/./}}"
  MANAGED_TARGET_PYTHON_PATH="${MANAGED_TARGET_PYTHON_HOME}/bin/python"
  MANAGED_TARGET_HANDOFF_MARKER="${MANAGED_TARGET_PYTHON_HOME}/.handoff-ready"
}

ansible.runtime.detect.python() {
  ANSIBLE_RUNTIME_SYSTEM_PYTHON="${PROXMOX_RUNTIME_SYSTEM_PYTHON:-$(command -v python3 2>/dev/null || true)}"
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_VERSION="$(ansible.runtime.python.version "${ANSIBLE_RUNTIME_SYSTEM_PYTHON}" || true)"
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_COMPATIBLE=0
  ANSIBLE_RUNTIME_SYSTEM_VENV_READY=0
  if ansible.runtime.python.compatible "${ANSIBLE_RUNTIME_SYSTEM_PYTHON}"; then
    ANSIBLE_RUNTIME_SYSTEM_PYTHON_COMPATIBLE=1
    if "${ANSIBLE_RUNTIME_SYSTEM_PYTHON}" -m ensurepip --version >/dev/null 2>&1; then
      ANSIBLE_RUNTIME_SYSTEM_VENV_READY=1
    fi
  fi

  ANSIBLE_RUNTIME_MANAGED_PYTHON="${MANAGED_TARGET_PYTHON_PATH}"
  ANSIBLE_RUNTIME_MANAGED_PYTHON_VERSION="$(ansible.runtime.python.version "${ANSIBLE_RUNTIME_MANAGED_PYTHON}" || true)"
  ANSIBLE_RUNTIME_MANAGED_PYTHON_READY=0
  if ansible.runtime.python.compatible "${ANSIBLE_RUNTIME_MANAGED_PYTHON}"; then
    ANSIBLE_RUNTIME_MANAGED_PYTHON_READY=1
  fi

  ANSIBLE_RUNTIME_SOURCE_PYTHON="${PYTHON_BIN}"
  ANSIBLE_RUNTIME_SOURCE_PYTHON_VERSION="$(ansible.runtime.python.version "${ANSIBLE_RUNTIME_SOURCE_PYTHON}" || true)"
  ANSIBLE_RUNTIME_SOURCE_PYTHON_READY=0
  if ansible.runtime.python.compatible "${ANSIBLE_RUNTIME_SOURCE_PYTHON}"; then
    ANSIBLE_RUNTIME_SOURCE_PYTHON_READY=1
  fi
}

ansible.runtime.detect.ansible() {
  local version_output="" version_line=""
  ANSIBLE_RUNTIME_ANSIBLE_READY=0
  ANSIBLE_RUNTIME_ANSIBLE_VERSION=""
  if [[ -x "${ANSIBLE_VENV_BIN}" && -x "${ANSIBLE_RUNTIME_PYTHON}" ]]; then
    version_output="$("${ANSIBLE_VENV_BIN}" --version 2>/dev/null || true)"
    version_line="${version_output%%$'\n'*}"
    ANSIBLE_RUNTIME_ANSIBLE_VERSION="${version_line}"
    if ansible.runtime.version.line.matches.policy "${version_line}" \
      && ansible.runtime.python.compatible "${ANSIBLE_RUNTIME_PYTHON}"; then
      ANSIBLE_RUNTIME_ANSIBLE_READY=1
    fi
  fi
}

ansible.runtime.resolve.policy() {
  ANSIBLE_RUNTIME_INSTALL_VENV_SUPPORT=0
  ANSIBLE_RUNTIME_BUILD_PYTHON=0

  if ((ANSIBLE_RUNTIME_SYSTEM_PYTHON_COMPATIBLE)); then
    ANSIBLE_RUNTIME_TARGET_PYTHON="${ANSIBLE_RUNTIME_SYSTEM_PYTHON}"
  elif ((ANSIBLE_RUNTIME_MANAGED_PYTHON_READY)); then
    ANSIBLE_RUNTIME_TARGET_PYTHON="${ANSIBLE_RUNTIME_MANAGED_PYTHON}"
  elif ((ANSIBLE_RUNTIME_SOURCE_PYTHON_READY)); then
    ANSIBLE_RUNTIME_TARGET_PYTHON="${ANSIBLE_RUNTIME_SOURCE_PYTHON}"
  elif ((ANSIBLE_RUNTIME_ANSIBLE_READY)); then
    ANSIBLE_RUNTIME_TARGET_PYTHON="${ANSIBLE_RUNTIME_PYTHON}"
  else
    ANSIBLE_RUNTIME_TARGET_PYTHON="${MANAGED_TARGET_PYTHON_PATH}"
  fi

  if ((ANSIBLE_RUNTIME_ANSIBLE_READY)); then
    ANSIBLE_RUNTIME_ANSIBLE_ACTION="reuse"
    ANSIBLE_RUNTIME_PYTHON_STRATEGY="existing_venv"
    ANSIBLE_RUNTIME_BOOTSTRAP_PYTHON="${ANSIBLE_RUNTIME_PYTHON}"
    return
  fi

  if [[ -x "${ANSIBLE_VENV_BIN}" || -d "${ANSIBLE_VENV}" ]]; then
    ANSIBLE_RUNTIME_ANSIBLE_ACTION="rebuild"
  else
    ANSIBLE_RUNTIME_ANSIBLE_ACTION="create"
  fi

  if ((ANSIBLE_RUNTIME_SYSTEM_PYTHON_COMPATIBLE)); then
    ANSIBLE_RUNTIME_PYTHON_STRATEGY="system"
    ANSIBLE_RUNTIME_BOOTSTRAP_PYTHON="${ANSIBLE_RUNTIME_SYSTEM_PYTHON}"
    if ((ANSIBLE_RUNTIME_SYSTEM_VENV_READY == 0)); then
      ANSIBLE_RUNTIME_INSTALL_VENV_SUPPORT=1
    fi
  elif ((ANSIBLE_RUNTIME_MANAGED_PYTHON_READY)); then
    ANSIBLE_RUNTIME_PYTHON_STRATEGY="managed_existing"
    ANSIBLE_RUNTIME_BOOTSTRAP_PYTHON="${ANSIBLE_RUNTIME_MANAGED_PYTHON}"
  elif ((ANSIBLE_RUNTIME_SOURCE_PYTHON_READY)); then
    ANSIBLE_RUNTIME_PYTHON_STRATEGY="source_existing"
    ANSIBLE_RUNTIME_BOOTSTRAP_PYTHON="${ANSIBLE_RUNTIME_SOURCE_PYTHON}"
  else
    ANSIBLE_RUNTIME_PYTHON_STRATEGY="source_build"
    ANSIBLE_RUNTIME_BOOTSTRAP_PYTHON="${MANAGED_TARGET_PYTHON_PATH}"
    ANSIBLE_RUNTIME_BUILD_PYTHON=1
  fi
}

ansible.runtime.yaml.quote() {
  local value="${1:-}"
  value="${value//\'/\'\'}"
  printf "'%s'" "${value}"
}

ansible.runtime.yaml.bool() {
  [[ "${1:-0}" == "1" ]] && printf 'true' || printf 'false'
}

ansible.runtime.vars.path() {
  local runtime_dir=""
  if [[ -n "${ANSIBLE_RUNTIME_VARS_PATH}" ]]; then
    printf '%s\n' "${ANSIBLE_RUNTIME_VARS_PATH}"
    return
  fi
  runtime_dir="${PROXMOX_RUNTIME_TMP_DIR:-${TMP_DIR:-/tmp/proxmox-ansible-runtime}}"
  if ! mkdir -p "${runtime_dir}" 2>/dev/null; then
    runtime_dir="/tmp/proxmox-ansible-runtime-${EUID:-$(id -u)}"
    mkdir -p "${runtime_dir}"
  fi
  ANSIBLE_RUNTIME_VARS_PATH="${runtime_dir}/runtime.${$}.yml"
  PROXMOX_RUNTIME_VARS_PATH="${ANSIBLE_RUNTIME_VARS_PATH}"
  export ANSIBLE_RUNTIME_VARS_PATH PROXMOX_RUNTIME_VARS_PATH
  printf '%s\n' "${ANSIBLE_RUNTIME_VARS_PATH}"
}

ansible.runtime.write.vars() {
  local vars_path="" bootstrap_mode="direct_handoff" bootstrap_raw="false"
  local effective_target_home="${MANAGED_TARGET_PYTHON_HOME}"
  local effective_target_path="${MANAGED_TARGET_PYTHON_PATH}"
  local effective_target_marker="${MANAGED_TARGET_HANDOFF_MARKER}"
  local effective_target_version="${PYTHON_VERSION}"
  local effective_target_major_minor="${PYTHON_MAJOR_MINOR}"
  ansible.runtime.vars.path >/dev/null
  vars_path="${ANSIBLE_RUNTIME_VARS_PATH}"
  if ((ANSIBLE_RUNTIME_BUILD_PYTHON)); then
    bootstrap_mode="bridge_required"
    bootstrap_raw="true"
  elif [[ "${ANSIBLE_RUNTIME_PYTHON_STRATEGY}" == "system" ]]; then
    effective_target_path="${ANSIBLE_RUNTIME_TARGET_PYTHON}"
    effective_target_home="${ANSIBLE_RUNTIME_TARGET_PYTHON%/bin/python*}"
    effective_target_marker=""
    effective_target_version="${ANSIBLE_RUNTIME_SYSTEM_PYTHON_VERSION:-${PYTHON_VERSION}}"
    effective_target_major_minor="${effective_target_version%.*}"
  elif [[ "${ANSIBLE_RUNTIME_TARGET_PYTHON}" != "${MANAGED_TARGET_PYTHON_PATH}" ]]; then
    effective_target_path="${ANSIBLE_RUNTIME_TARGET_PYTHON}"
    effective_target_home="${ANSIBLE_RUNTIME_TARGET_PYTHON%/bin/python*}"
    effective_target_marker=""
    effective_target_version="$(ansible.runtime.python.version "${ANSIBLE_RUNTIME_TARGET_PYTHON}" || printf '%s' "${PYTHON_VERSION}")"
    effective_target_major_minor="${effective_target_version%.*}"
  fi
  cat > "${vars_path}" <<EOF
---
proxmox_runtime:
  schema_version: 1
  context: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_CONTEXT}")
  supported: $(ansible.runtime.yaml.bool "${ANSIBLE_RUNTIME_SUPPORTED}")
  error: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_ERROR}")
  pve:
    present: $(ansible.runtime.yaml.bool "${ANSIBLE_RUNTIME_PVE_PRESENT}")
    version: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_PVE_VERSION}")
    major: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_PVE_MAJOR}")
  debian:
    id: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_DEBIAN_ID}")
    version: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_DEBIAN_VERSION}")
    codename: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_DEBIAN_CODENAME}")
  python:
    required_minimum: $(ansible.runtime.yaml.quote "${PROXMOX_RUNTIME_PYTHON_MIN_MAJOR}.${PROXMOX_RUNTIME_PYTHON_MIN_MINOR}")
    system_path: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_SYSTEM_PYTHON}")
    system_version: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_SYSTEM_PYTHON_VERSION}")
    system_compatible: $(ansible.runtime.yaml.bool "${ANSIBLE_RUNTIME_SYSTEM_PYTHON_COMPATIBLE}")
    system_venv_ready: $(ansible.runtime.yaml.bool "${ANSIBLE_RUNTIME_SYSTEM_VENV_READY}")
    fallback_version: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_FALLBACK_VERSION}")
    strategy: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_PYTHON_STRATEGY}")
    bootstrap_path: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_BOOTSTRAP_PYTHON}")
    target_path: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_TARGET_PYTHON}")
  ansible:
    core_version: $(ansible.runtime.yaml.quote "${ANSIBLE_CORE_VERSION}")
    venv: $(ansible.runtime.yaml.quote "${ANSIBLE_VENV}")
    ready: $(ansible.runtime.yaml.bool "${ANSIBLE_RUNTIME_ANSIBLE_READY}")
    action: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_ANSIBLE_ACTION}")
  steps:
    install_venv_support: $(ansible.runtime.yaml.bool "${ANSIBLE_RUNTIME_INSTALL_VENV_SUPPORT}")
    build_python: $(ansible.runtime.yaml.bool "${ANSIBLE_RUNTIME_BUILD_PYTHON}")
    rebuild_ansible_venv: $(ansible.runtime.yaml.bool "$([[ "${ANSIBLE_RUNTIME_ANSIBLE_ACTION}" == "rebuild" ]] && printf 1 || printf 0)")
ansible_python_interpreter_system: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_SYSTEM_PYTHON:-/usr/bin/python3}")
ansible_python_interpreter_managed: $(ansible.runtime.yaml.quote "${ANSIBLE_RUNTIME_TARGET_PYTHON}")
managed_target_python_version: $(ansible.runtime.yaml.quote "${effective_target_version}")
managed_target_python_major_minor: $(ansible.runtime.yaml.quote "${effective_target_major_minor}")
managed_target_python_home: $(ansible.runtime.yaml.quote "${effective_target_home}")
managed_target_python_path: $(ansible.runtime.yaml.quote "${effective_target_path}")
managed_target_handoff_marker: $(ansible.runtime.yaml.quote "${effective_target_marker}")
bootstrap_mode: $(ansible.runtime.yaml.quote "${bootstrap_mode}")
bootstrap_use_raw_only: ${bootstrap_raw}
bootstrap_needs_target_python_build: $(ansible.runtime.yaml.bool "${ANSIBLE_RUNTIME_BUILD_PYTHON}")
EOF
}

ansible.runtime.prepare() {
  local requested_context="${1:-${PROXMOX_RUNTIME_CONTEXT:-auto}}"
  ansible.runtime.detect.platform "${requested_context}"
  ansible.runtime.select.fallback
  ansible.runtime.detect.python
  ansible.runtime.detect.ansible
  ansible.runtime.resolve.policy
  ANSIBLE_RUNTIME_PREPARED=1
  ansible.runtime.write.vars
  export ANSIBLE_RUNTIME_CONTEXT ANSIBLE_RUNTIME_PYTHON_STRATEGY
  export ANSIBLE_RUNTIME_BOOTSTRAP_PYTHON ANSIBLE_RUNTIME_TARGET_PYTHON
  export ANSIBLE_RUNTIME_BUILD_PYTHON ANSIBLE_RUNTIME_INSTALL_VENV_SUPPORT
  if ((ANSIBLE_RUNTIME_SUPPORTED == 0)); then
    ansible.runtime.error "${ANSIBLE_RUNTIME_ERROR}"
    return 20
  fi
}

ansible.runtime.require() {
  local version_output="" version_line=""

  if ((ANSIBLE_RUNTIME_PREPARED == 0)); then
    ansible.runtime.prepare "${PROXMOX_RUNTIME_CONTEXT:-auto}" || return $?
  fi
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
  local arg_count="$#" playbook_path=""
  local -a ansible_args=()

  ((arg_count > 0)) || {
    ansible.runtime.error "ansible.runtime.run requires a playbook path"
    return 10
  }
  if ((ANSIBLE_RUNTIME_PREPARED == 0)); then
    ansible.runtime.prepare "${PROXMOX_RUNTIME_CONTEXT:-auto}" || return $?
  fi
  ansible.runtime.require || return $?
  ansible.runtime.write.vars
  playbook_path="${!arg_count}"
  if ((arg_count > 1)); then
    ansible_args=("${@:1:arg_count-1}")
  fi
  "${ANSIBLE_PLAYBOOK_BIN}" \
    "${ansible_args[@]}" \
    -e "@${ANSIBLE_RUNTIME_VARS_PATH}" \
    -e "ansible_python_interpreter=${ANSIBLE_RUNTIME_TARGET_PYTHON:-${ANSIBLE_RUNTIME_PYTHON}}" \
    "${playbook_path}"
}

ansible.runtime.report() {
  printf 'context=%s pve=%s debian=%s python=%s compatible=%s strategy=%s ansible=%s action=%s build_python=%s vars=%s\n' \
    "${ANSIBLE_RUNTIME_CONTEXT}" \
    "${ANSIBLE_RUNTIME_PVE_VERSION:-none}" \
    "${ANSIBLE_RUNTIME_DEBIAN_CODENAME:-${ANSIBLE_RUNTIME_DEBIAN_VERSION:-unknown}}" \
    "${ANSIBLE_RUNTIME_SYSTEM_PYTHON_VERSION:-missing}" \
    "${ANSIBLE_RUNTIME_SYSTEM_PYTHON_COMPATIBLE}" \
    "${ANSIBLE_RUNTIME_PYTHON_STRATEGY}" \
    "${ANSIBLE_RUNTIME_ANSIBLE_VERSION:-missing}" \
    "${ANSIBLE_RUNTIME_ANSIBLE_ACTION}" \
    "${ANSIBLE_RUNTIME_BUILD_PYTHON}" \
    "${ANSIBLE_RUNTIME_VARS_PATH}"
}

ansible.runtime.main() {
  local action="${1:-check}" context="${PROXMOX_RUNTIME_CONTEXT:-auto}" format="human"
  shift || true
  while (($# > 0)); do
    case "$1" in
      --context) context="${2:-}"; shift 2 ;;
      --format) format="${2:-}"; shift 2 ;;
      *) ansible.runtime.error "unknown argument: $1"; return 20 ;;
    esac
  done
  [[ "${action}" == "check" ]] || {
    ansible.runtime.error "supported action: check"
    return 20
  }
  ansible.runtime.prepare "${context}" || return $?
  case "${format}" in
    human) ansible.runtime.report ;;
    yaml) cat "${ANSIBLE_RUNTIME_VARS_PATH}" ;;
    *) ansible.runtime.error "unsupported format: ${format}"; return 20 ;;
  esac
  ((ANSIBLE_RUNTIME_ANSIBLE_READY)) && return 0
  return 10
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
  ansible.runtime.main "$@"
fi
