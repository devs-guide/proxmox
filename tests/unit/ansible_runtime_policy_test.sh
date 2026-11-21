#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP}"' EXIT

PROXMOX_RUNTIME_TMP_DIR="${TEST_TMP}/runtime"
# shellcheck source=../../bootstrap/ansible.runtime.sh
source "${ROOT}/bootstrap/ansible.runtime.sh"

fail() {
  printf '[ansible.runtime.test][error] %s\n' "$*" >&2
  exit 1
}

assert.eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "${actual}" == "${expected}" ]] \
    || fail "${label}: expected=${expected}, actual=${actual}"
}

reset.policy() {
  ANSIBLE_VENV="/opt/ansible-venv"
  ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
  ANSIBLE_RUNTIME_PYTHON="${ANSIBLE_VENV}/bin/python"
  ANSIBLE_RUNTIME_SYSTEM_PYTHON="/usr/bin/python3"
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_VERSION=""
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_COMPATIBLE=0
  ANSIBLE_RUNTIME_SYSTEM_VENV_READY=0
  ANSIBLE_RUNTIME_MANAGED_PYTHON="/opt/ansible/managed/bin/python"
  ANSIBLE_RUNTIME_MANAGED_PYTHON_READY=0
  ANSIBLE_RUNTIME_SOURCE_PYTHON="/usr/local/bin/python3.12"
  ANSIBLE_RUNTIME_SOURCE_PYTHON_READY=0
  ANSIBLE_RUNTIME_ANSIBLE_READY=0
  ANSIBLE_RUNTIME_ANSIBLE_ACTION="create"
  ANSIBLE_RUNTIME_ANSIBLE_VERSION=""
  ANSIBLE_RUNTIME_CONTEXT="debian_host"
  ANSIBLE_RUNTIME_PVE_PRESENT=0
  ANSIBLE_RUNTIME_PVE_VERSION=""
  ANSIBLE_RUNTIME_PVE_MAJOR=""
  ANSIBLE_RUNTIME_DEBIAN_ID="debian"
  ANSIBLE_RUNTIME_DEBIAN_VERSION=""
  ANSIBLE_RUNTIME_DEBIAN_CODENAME=""
  ANSIBLE_RUNTIME_SUPPORTED=1
  ANSIBLE_RUNTIME_ERROR=""
  ANSIBLE_RUNTIME_VARS_PATH=""
  unset PROXMOX_BOOTSTRAP_PYTHON_VERSION PROXMOX_BOOTSTRAP_MANAGED_TARGET_PYTHON_HOME
}

case.pve9.native() {
  reset.policy
  ANSIBLE_RUNTIME_CONTEXT="pve_host"
  ANSIBLE_RUNTIME_PVE_PRESENT=1
  ANSIBLE_RUNTIME_PVE_VERSION="9.1"
  ANSIBLE_RUNTIME_PVE_MAJOR="9"
  ANSIBLE_RUNTIME_DEBIAN_VERSION="13"
  ANSIBLE_RUNTIME_DEBIAN_CODENAME="trixie"
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_VERSION="3.13.5"
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_COMPATIBLE=1
  ANSIBLE_RUNTIME_SYSTEM_VENV_READY=1
  ansible.runtime.select.fallback
  ansible.runtime.resolve.policy
  assert.eq system "${ANSIBLE_RUNTIME_PYTHON_STRATEGY}" "PVE 9 strategy"
  assert.eq 0 "${ANSIBLE_RUNTIME_BUILD_PYTHON}" "PVE 9 build decision"
  assert.eq 3.13.5 "${PYTHON_VERSION}" "PVE 9 fallback pin"
}

case.pve9.reuse.without.managed.handoff() {
  reset.policy
  ANSIBLE_RUNTIME_CONTEXT="pve_host"
  ANSIBLE_RUNTIME_PVE_PRESENT=1
  ANSIBLE_RUNTIME_PVE_VERSION="9.2.21"
  ANSIBLE_RUNTIME_PVE_MAJOR="9"
  ANSIBLE_RUNTIME_DEBIAN_VERSION="13"
  ANSIBLE_RUNTIME_DEBIAN_CODENAME="trixie"
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_VERSION="3.13.5"
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_COMPATIBLE=1
  ANSIBLE_RUNTIME_SYSTEM_VENV_READY=1
  ANSIBLE_RUNTIME_MANAGED_PYTHON="/opt/ansible/py312/bin/python"
  ANSIBLE_RUNTIME_MANAGED_PYTHON_READY=0
  ANSIBLE_RUNTIME_ANSIBLE_READY=1
  ANSIBLE_RUNTIME_ANSIBLE_VERSION="ansible-playbook [core ${ANSIBLE_CORE_VERSION}]"
  ansible.runtime.select.fallback
  ansible.runtime.resolve.policy
  assert.eq existing_venv "${ANSIBLE_RUNTIME_PYTHON_STRATEGY}" "PVE 9 existing Ansible strategy without managed handoff"
  assert.eq reuse "${ANSIBLE_RUNTIME_ANSIBLE_ACTION}" "PVE 9 existing Ansible action without managed handoff"
  assert.eq 0 "${ANSIBLE_RUNTIME_BUILD_PYTHON}" "PVE 9 existing Ansible build decision without managed handoff"
  assert.eq /usr/bin/python3 "${ANSIBLE_RUNTIME_TARGET_PYTHON}" "PVE 9 target interpreter without managed handoff"
}

case.old.release() {
  local pve_major="$1" codename="$2" debian_version="$3"
  reset.policy
  ANSIBLE_RUNTIME_CONTEXT="pve_host"
  ANSIBLE_RUNTIME_PVE_PRESENT=1
  ANSIBLE_RUNTIME_PVE_VERSION="${pve_major}.0"
  ANSIBLE_RUNTIME_PVE_MAJOR="${pve_major}"
  ANSIBLE_RUNTIME_DEBIAN_VERSION="${debian_version}"
  ANSIBLE_RUNTIME_DEBIAN_CODENAME="${codename}"
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_VERSION="3.11.0"
  ansible.runtime.select.fallback
  ansible.runtime.resolve.policy
  assert.eq source_build "${ANSIBLE_RUNTIME_PYTHON_STRATEGY}" "PVE ${pve_major} strategy"
  assert.eq 1 "${ANSIBLE_RUNTIME_BUILD_PYTHON}" "PVE ${pve_major} build decision"
  assert.eq 3.12.3 "${PYTHON_VERSION}" "PVE ${pve_major} fallback pin"
}

case.container.matrix() {
  reset.policy
  ANSIBLE_RUNTIME_CONTEXT="debian_container"
  ANSIBLE_RUNTIME_DEBIAN_VERSION="13"
  ANSIBLE_RUNTIME_DEBIAN_CODENAME="trixie"
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_VERSION="3.13.5"
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_COMPATIBLE=1
  ANSIBLE_RUNTIME_SYSTEM_VENV_READY=1
  ansible.runtime.select.fallback
  ansible.runtime.resolve.policy
  assert.eq system "${ANSIBLE_RUNTIME_PYTHON_STRATEGY}" "Debian 13 container strategy"
  assert.eq 0 "${ANSIBLE_RUNTIME_BUILD_PYTHON}" "Debian 13 container build decision"

  reset.policy
  ANSIBLE_RUNTIME_CONTEXT="debian_container"
  ANSIBLE_RUNTIME_DEBIAN_VERSION="12"
  ANSIBLE_RUNTIME_DEBIAN_CODENAME="bookworm"
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_VERSION="3.11.2"
  ansible.runtime.select.fallback
  ansible.runtime.resolve.policy
  assert.eq source_build "${ANSIBLE_RUNTIME_PYTHON_STRATEGY}" "Debian 12 container strategy"
  assert.eq 1 "${ANSIBLE_RUNTIME_BUILD_PYTHON}" "Debian 12 container build decision"
}

case.reuse.and.repair() {
  reset.policy
  ANSIBLE_RUNTIME_ANSIBLE_READY=1
  ANSIBLE_RUNTIME_ANSIBLE_VERSION="ansible-playbook [core ${ANSIBLE_CORE_VERSION}]"
  ansible.runtime.select.fallback
  ansible.runtime.resolve.policy
  assert.eq existing_venv "${ANSIBLE_RUNTIME_PYTHON_STRATEGY}" "valid venv strategy"
  assert.eq reuse "${ANSIBLE_RUNTIME_ANSIBLE_ACTION}" "valid venv action"
  assert.eq 0 "${ANSIBLE_RUNTIME_BUILD_PYTHON}" "valid venv build decision"

  reset.policy
  ANSIBLE_RUNTIME_SYSTEM_PYTHON_COMPATIBLE=1
  ANSIBLE_RUNTIME_SYSTEM_VENV_READY=0
  ANSIBLE_VENV="${TEST_TMP}/broken-venv"
  ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
  ANSIBLE_RUNTIME_PYTHON="${ANSIBLE_VENV}/bin/python"
  mkdir -p "${ANSIBLE_VENV}"
  ansible.runtime.select.fallback
  ansible.runtime.resolve.policy
  assert.eq system "${ANSIBLE_RUNTIME_PYTHON_STRATEGY}" "repair strategy"
  assert.eq rebuild "${ANSIBLE_RUNTIME_ANSIBLE_ACTION}" "repair action"
  assert.eq 1 "${ANSIBLE_RUNTIME_INSTALL_VENV_SUPPORT}" "repair venv-support action"
}

case.existing.fallbacks() {
  reset.policy
  ANSIBLE_RUNTIME_MANAGED_PYTHON_READY=1
  ansible.runtime.select.fallback
  ansible.runtime.resolve.policy
  assert.eq managed_existing "${ANSIBLE_RUNTIME_PYTHON_STRATEGY}" "existing managed strategy"
  assert.eq 0 "${ANSIBLE_RUNTIME_BUILD_PYTHON}" "existing managed build decision"

  reset.policy
  ANSIBLE_RUNTIME_SOURCE_PYTHON_READY=1
  ansible.runtime.select.fallback
  ansible.runtime.resolve.policy
  assert.eq source_existing "${ANSIBLE_RUNTIME_PYTHON_STRATEGY}" "existing source strategy"
  assert.eq 0 "${ANSIBLE_RUNTIME_BUILD_PYTHON}" "existing source build decision"
}

case.platform.contract() {
  mkdir -p "${TEST_TMP}/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "pve-manager/9.1.4/abcd"' > "${TEST_TMP}/bin/pveversion"
  chmod 0755 "${TEST_TMP}/bin/pveversion"
  printf '%s\n' 'ID=debian' 'VERSION_ID="13"' 'VERSION_CODENAME=trixie' > "${TEST_TMP}/os-release"

  PATH="${TEST_TMP}/bin:${PATH}"
  PROXMOX_RUNTIME_OS_RELEASE_PATH="${TEST_TMP}/os-release"
  PROXMOX_RUNTIME_EXPECT_PVE_MAJOR=9
  PROXMOX_RUNTIME_EXPECT_DEBIAN_CODENAME=trixie
  ansible.runtime.detect.platform host
  assert.eq 1 "${ANSIBLE_RUNTIME_SUPPORTED}" "matching platform contract"
  assert.eq 9 "${ANSIBLE_RUNTIME_PVE_MAJOR}" "detected PVE major"
  assert.eq trixie "${ANSIBLE_RUNTIME_DEBIAN_CODENAME}" "detected Debian codename"

  PROXMOX_RUNTIME_EXPECT_PVE_MAJOR=8
  ansible.runtime.detect.platform host
  assert.eq 0 "${ANSIBLE_RUNTIME_SUPPORTED}" "mismatched platform contract"

  PROXMOX_RUNTIME_EXPECT_PVE_MAJOR=9
  printf '%s\n' 'ID=debian' 'VERSION_ID="12"' 'VERSION_CODENAME=bookworm' > "${TEST_TMP}/os-release"
  ansible.runtime.detect.platform host
  assert.eq 0 "${ANSIBLE_RUNTIME_SUPPORTED}" "mismatched PVE/Debian release mapping"
  unset PROXMOX_RUNTIME_EXPECT_PVE_MAJOR PROXMOX_RUNTIME_EXPECT_DEBIAN_CODENAME
}

case.generated.vars() {
  case.pve9.native
  ansible.runtime.write.vars
  [[ -s "${ANSIBLE_RUNTIME_VARS_PATH}" ]] || fail "runtime vars file was not written"
  grep -Fq 'schema_version: 1' "${ANSIBLE_RUNTIME_VARS_PATH}" || fail "runtime vars schema is missing"
  grep -Fq 'build_python: false' "${ANSIBLE_RUNTIME_VARS_PATH}" || fail "runtime build decision is missing"
  grep -Fq "ansible_python_interpreter_managed: '/usr/bin/python3'" "${ANSIBLE_RUNTIME_VARS_PATH}" \
    || fail "runtime managed-interpreter alias is missing"
  grep -Fq "managed_target_handoff_marker: ''" "${ANSIBLE_RUNTIME_VARS_PATH}" \
    || fail "native system Python runtime must not advertise a managed handoff prerequisite"
}

case.cleanup.guard() {
  log() { :; }
  log.error() { :; }
  # shellcheck source=../../bootstrap/release.common.sh
  source "${ROOT}/bootstrap/release.common.sh"
  python.source.cleanup.target.safe /usr/local/src/Python-3.12.3 3.12.3 \
    || fail "known Python source cleanup target was rejected"
  ! python.source.cleanup.target.safe /tmp/Python-3.12.3 3.12.3 \
    || fail "unsafe Python source cleanup target was accepted"
  ! python.source.cleanup.target.safe /usr/local/src/Python-3.12.3 invalid \
    || fail "invalid Python version was accepted for source cleanup"
}

case.pve9.native
case.pve9.reuse.without.managed.handoff
case.old.release 8 bookworm 12
case.old.release 7 bullseye 11
case.old.release 6 buster 10
case.container.matrix
case.reuse.and.repair
case.existing.fallbacks
case.platform.contract
case.generated.vars
case.cleanup.guard

printf '[ansible.runtime.test][ok] platform/runtime policy matrix passed\n'
