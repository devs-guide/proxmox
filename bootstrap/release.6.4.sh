#!/usr/bin/env bash
## Bootstrap Proxmox VE 6.4 (Buster) repair + ansible playlist runner.
## Usage:
##   wget -qO- https://devs-guide.github.io/proxmox/6.4.sh | bash

set -euo pipefail

log()      { printf '[pve-6.4] %s\n' "$*" >&2; }
log.error(){ printf '[pve-6.4][error] %s\n' "$*" >&2; }

TMP_DIR="/tmp/pve-6.4"
PAGES_BASE_URL="https://devs-guide.github.io/proxmox"
BASE_URL="${PAGES_BASE_URL}/ansible/release/6.4"
DEBIAN_BASE_URL="${PAGES_BASE_URL}/ansible/debian"
DELL_BASE_URL="${PAGES_BASE_URL}/ansible/dell"
PLAYLIST="install.playbooks.txt"
PLAYLIST_URL="${BASE_URL}/${PLAYLIST}"
PLAYLIST_PATH="${TMP_DIR}/${PLAYLIST}"
GROUP_VARS_DIR="${TMP_DIR}/group_vars"
BASE_GROUP_VARS_FILE="base.yml"
BUSTER_GROUP_VARS_FILE="buster.yml"
GROUP_VARS_FILE="all.yml"
BASE_GROUP_VARS_URL="${PAGES_BASE_URL}/ansible/group_vars/all.yml"
BUSTER_GROUP_VARS_URL="${PAGES_BASE_URL}/ansible/group_vars/${BUSTER_GROUP_VARS_FILE}"
GROUP_VARS_URL="${BASE_URL}/group_vars/${GROUP_VARS_FILE}"
BASE_GROUP_VARS_PATH="${GROUP_VARS_DIR}/${BASE_GROUP_VARS_FILE}"
BUSTER_GROUP_VARS_PATH="${GROUP_VARS_DIR}/${BUSTER_GROUP_VARS_FILE}"
GROUP_VARS_PATH="${GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
MERGED_GROUP_VARS_PATH="${GROUP_VARS_DIR}/combined.yml"
PLATFORM_GROUP_VARS_LABEL="buster"
PLATFORM_GROUP_VARS_LOG_LABEL="Buster"
PLATFORM_GROUP_VARS_URL="${BUSTER_GROUP_VARS_URL}"
PLATFORM_GROUP_VARS_PATH="${BUSTER_GROUP_VARS_PATH}"
PYTHON_VERSION="3.12.3"
PYTHON_MAJOR_MINOR="3.12"
PYTHON_SOURCE_PREFIX="/usr/local"
PYTHON_BIN="${PYTHON_SOURCE_PREFIX}/bin/python${PYTHON_MAJOR_MINOR}"
PYTHON_SRC_DIR="${PYTHON_SOURCE_PREFIX}/src/Python-${PYTHON_VERSION}"
PYTHON_SRC_ARCHIVE="${PYTHON_SRC_DIR}.tgz"
PYTHON_SRC_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"
ANSIBLE_VENV="/opt/ansible-venv"
ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
ANSIBLE_CORE_SPEC="ansible-core>=2.19,<2.20"
MANAGED_TARGET_PYTHON_HOME="/opt/ansible/py312"
MANAGED_TARGET_PYTHON_PATH="${MANAGED_TARGET_PYTHON_HOME}/bin/python"
PYTHON_BOOTSTRAP_BIN=""
RELEASE_LABEL="6.4"
COMMON_HELPER_NAME="release.common.sh"
COMMON_HELPER_URL="${PAGES_BASE_URL}/${COMMON_HELPER_NAME}"
COMMON_HELPER_PATH="${TMP_DIR}/${COMMON_HELPER_NAME}"

source.release.common() {
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  if [[ -n "${script_dir}" && -r "${script_dir}/${COMMON_HELPER_NAME}" ]]; then
    # shellcheck source=bootstrap/release.common.sh
    source "${script_dir}/${COMMON_HELPER_NAME}"
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
  # shellcheck source=/tmp/pve-6.4/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

source.release.common

require.pve6() {
  if command -v pveversion >/dev/null 2>&1; then
    if pveversion | grep -qE '^pve-manager/6\.'; then
      return
    fi
  fi
  if grep -qi 'proxmox' /etc/issue 2>/dev/null && grep -q '6\.' /etc/issue 2>/dev/null; then
    return
  fi
  log.error "This helper is only for Proxmox VE 6.x hosts."
  exit 1
}

prepare.buster.archives() {
  log "Preparing archived Debian/Proxmox repos for Buster..."
  cat > /etc/apt/sources.list <<'EOF'
deb http://archive.debian.org/debian buster main contrib non-free
deb-src http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main contrib non-free
deb-src http://archive.debian.org/debian-security buster/updates main contrib non-free
EOF

  cat > /etc/apt/apt.conf.d/99-archive-buster <<'EOF'
Acquire::Check-Valid-Until "false";
Acquire::AllowInsecureRepositories "true";
EOF

  rm -f /etc/apt/sources.list.d/pve-enterprise.list
  cat > /etc/apt/sources.list.d/pve-no-subscription.list <<'EOF'
deb http://archive.proxmox.com/debian/pve buster pve-no-subscription
EOF
}

main() {
  require.root
  require.apt
  require.pve6
  prepare.buster.archives
  maybe.run.ansible
}

main "$@"
