#!/usr/bin/env bash
## Bootstrap Proxmox VE 9.1 (Trixie) installer/config runner.
## Usage:
##   wget -qO- https://devs-guide.github.io/proxmox/9.1.sh | bash

set -euo pipefail

log()       { printf '[pve-9.1] %s\n' "$*" >&2; }
log.error() { printf '[pve-9.1][error] %s\n' "$*" >&2; }

TMP_DIR="/tmp/pve-9.1"
PAGES_BASE_URL="https://devs-guide.github.io/proxmox"
BASE_URL="${PAGES_BASE_URL}/ansible/release/9.1"
DEBIAN_BASE_URL="${PAGES_BASE_URL}/ansible/debian"
DELL_BASE_URL="${PAGES_BASE_URL}/ansible/dell"
PLAYLIST="install.playbooks.txt"
PLAYLIST_URL="${BASE_URL}/${PLAYLIST}"
PLAYLIST_PATH="${TMP_DIR}/${PLAYLIST}"
GROUP_VARS_DIR="${TMP_DIR}/group_vars"
BASE_GROUP_VARS_FILE="base.yml"
TRIXIE_GROUP_VARS_FILE="trixie.yml"
GROUP_VARS_FILE="all.yml"
BASE_GROUP_VARS_URL="${PAGES_BASE_URL}/ansible/group_vars/all.yml"
TRIXIE_GROUP_VARS_URL="${PAGES_BASE_URL}/ansible/group_vars/${TRIXIE_GROUP_VARS_FILE}"
GROUP_VARS_URL="${BASE_URL}/group_vars/${GROUP_VARS_FILE}"
BASE_GROUP_VARS_PATH="${GROUP_VARS_DIR}/${BASE_GROUP_VARS_FILE}"
TRIXIE_GROUP_VARS_PATH="${GROUP_VARS_DIR}/${TRIXIE_GROUP_VARS_FILE}"
GROUP_VARS_PATH="${GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
MERGED_GROUP_VARS_PATH="${GROUP_VARS_DIR}/combined.yml"
PLATFORM_GROUP_VARS_LABEL="trixie"
PLATFORM_GROUP_VARS_LOG_LABEL="Trixie"
PLATFORM_GROUP_VARS_URL="${TRIXIE_GROUP_VARS_URL}"
PLATFORM_GROUP_VARS_PATH="${TRIXIE_GROUP_VARS_PATH}"
PROXMOX_KEY_PATH="/etc/apt/keyrings/proxmox-release-trixie.gpg"
PROXMOX_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg"
PYTHON_VERSION="3.12.3"
PYTHON_MAJOR_MINOR="3.12"
PYTHON_SOURCE_PREFIX="/usr/local"
PYTHON_BIN="${PYTHON_SOURCE_PREFIX}/bin/python${PYTHON_MAJOR_MINOR}"
PYTHON_SRC_DIR="${PYTHON_SOURCE_PREFIX}/src/Python-${PYTHON_VERSION}"
PYTHON_SRC_ARCHIVE="${PYTHON_SRC_DIR}.tgz"
PYTHON_SRC_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"
ANSIBLE_VENV="/opt/ansible-venv"
ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
ANSIBLE_CORE_SPEC="ansible-core>=2.20,<2.21"
MANAGED_TARGET_PYTHON_HOME="/opt/ansible/py312"
MANAGED_TARGET_PYTHON_PATH="${MANAGED_TARGET_PYTHON_HOME}/bin/python"
MANAGED_TARGET_HANDOFF_MARKER="${MANAGED_TARGET_PYTHON_HOME}/.handoff-ready"
PYTHON_BOOTSTRAP_BIN=""
RELEASE_LABEL="9.1"
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
  # shellcheck source=/tmp/pve-9.1/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

source.release.common

ensure.proxmox.key() {
  mkdir -p /etc/apt/keyrings
  if [ -f "${PROXMOX_KEY_PATH}" ]; then
    return
  fi
  log "Fetching Proxmox signing key..."
  if ! wget -qO "${PROXMOX_KEY_PATH}" "${PROXMOX_KEY_URL}"; then
    log.error "Failed to download Proxmox key from ${PROXMOX_KEY_URL}"
    exit 1
  fi
  chmod 0644 "${PROXMOX_KEY_PATH}"
}

require.pve9_or_trixie() {
  if command -v pveversion >/dev/null 2>&1; then
    if pveversion | grep -qE '^pve-manager/9\.'; then
      return
    fi
  fi
  if [ -f /etc/os-release ]; then
    if grep -q 'VERSION_CODENAME=.*trixie' /etc/os-release; then
      return
    fi
    if grep -qi 'debian.*13' /etc/os-release; then
      return
    fi
  fi
  log.error "This helper targets Proxmox VE 9.x / Debian 13 (Trixie)."
  exit 1
}

prepare.trixie.sources() {
  log "Configuring Debian Trixie and Proxmox 9.x repositories (deb822)..."
  mkdir -p /etc/apt/keyrings

  ensure.proxmox.key

  cat > /etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

  cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: ${PROXMOX_KEY_PATH}
EOF

  rm -f /etc/apt/sources.list.d/pve-enterprise.list
  apt-get update -y
}

main() {
  require.root
  require.apt
  require.pve9_or_trixie
  prepare.trixie.sources
  maybe.run.ansible
}

main "$@"
