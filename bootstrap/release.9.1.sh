#!/usr/bin/env bash
## Bootstrap Proxmox VE 9.1 (Trixie) installer/config runner.
## Usage:
##   wget -qO- https://devs-guide.github.io/proxmox/9.1.sh | bash

set -euo pipefail

log()       { printf '[pve-9.1] %s\n' "$*" >&2; }
log.error() { printf '[pve-9.1][error] %s\n' "$*" >&2; }

TMP_DIR="/tmp/pve-9.1"
BASE_URL="https://devs-guide.github.io/proxmox/ansible/release/9.1"
DEBIAN_BASE_URL="https://devs-guide.github.io/proxmox/ansible/debian"
DELL_BASE_URL="https://devs-guide.github.io/proxmox/ansible/dell"
PLAYLIST="install.playbooks.txt"
PLAYLIST_URL="${BASE_URL}/${PLAYLIST}"
PLAYLIST_PATH="${TMP_DIR}/${PLAYLIST}"
GROUP_VARS_DIR="${TMP_DIR}/group_vars"
BASE_GROUP_VARS_FILE="base.yml"
TRIXIE_GROUP_VARS_FILE="trixie.yml"
GROUP_VARS_FILE="all.yml"
BASE_GROUP_VARS_URL="https://devs-guide.github.io/proxmox/ansible/group_vars/all.yml"
TRIXIE_GROUP_VARS_URL="https://devs-guide.github.io/proxmox/ansible/group_vars/${TRIXIE_GROUP_VARS_FILE}"
GROUP_VARS_URL="${BASE_URL}/group_vars/${GROUP_VARS_FILE}"
BASE_GROUP_VARS_PATH="${GROUP_VARS_DIR}/${BASE_GROUP_VARS_FILE}"
TRIXIE_GROUP_VARS_PATH="${GROUP_VARS_DIR}/${TRIXIE_GROUP_VARS_FILE}"
GROUP_VARS_PATH="${GROUP_VARS_DIR}/${GROUP_VARS_FILE}"
MERGED_GROUP_VARS_PATH="${GROUP_VARS_DIR}/combined.yml"
PROXMOX_KEY_PATH="/etc/apt/keyrings/proxmox-release-trixie.gpg"
PROXMOX_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg"
PYTHON_VERSION="3.12.3"
PYTHON_MAJOR_MINOR="3.12"
PYTHON_PREFIX="/usr/local"
PYTHON_BIN="${PYTHON_PREFIX}/bin/python${PYTHON_MAJOR_MINOR}"
PYTHON_SRC_DIR="${PYTHON_PREFIX}/src/Python-${PYTHON_VERSION}"
PYTHON_SRC_ARCHIVE="${PYTHON_SRC_DIR}.tgz"
PYTHON_SRC_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"
ANSIBLE_VENV="/opt/ansible-venv"
ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
ANSIBLE_CORE_SPEC="ansible-core>=2.19,<2.20"
PYTHON_BOOTSTRAP_BIN=""

require.root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log.error "Run as root."
    exit 1
  fi
}

require.apt() {
  if ! command -v apt-get >/dev/null 2>&1; then
    log.error "apt-get not found; expected Proxmox/Debian-like system."
    exit 1
  fi
}

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

ensure.python312() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v "python${PYTHON_MAJOR_MINOR}" >/dev/null 2>&1; then
    PYTHON_BOOTSTRAP_BIN="$(command -v "python${PYTHON_MAJOR_MINOR}")"
    log "Using existing system Python: $("${PYTHON_BOOTSTRAP_BIN}" --version 2>&1)"
    return
  fi

  if [[ -x "${PYTHON_BIN}" ]]; then
    PYTHON_BOOTSTRAP_BIN="${PYTHON_BIN}"
    log "Using existing local Python: $("${PYTHON_BOOTSTRAP_BIN}" --version 2>&1)"
    return
  fi

  log "Installing Python ${PYTHON_VERSION} build prerequisites..."
  apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    libncursesw5-dev \
    tk-dev \
    libgdbm-dev \
    libgdbm-compat-dev \
    liblzma-dev \
    libffi-dev \
    uuid-dev \
    wget \
    curl \
    ca-certificates \
    xz-utils

  mkdir -p "${PYTHON_PREFIX}/src"
  if [[ ! -s "${PYTHON_SRC_ARCHIVE}" ]]; then
    log "Downloading Python ${PYTHON_VERSION} source..."
    wget -qO "${PYTHON_SRC_ARCHIVE}" "${PYTHON_SRC_URL}"
  fi

  if [[ ! -d "${PYTHON_SRC_DIR}" ]]; then
    log "Unpacking Python ${PYTHON_VERSION} source..."
    tar -xzf "${PYTHON_SRC_ARCHIVE}" -C "${PYTHON_PREFIX}/src"
  fi

  log "Building Python ${PYTHON_VERSION}..."
  (
    cd "${PYTHON_SRC_DIR}"
    ./configure --enable-optimizations --with-ensurepip=install
    make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    make altinstall
  )

  PYTHON_BOOTSTRAP_BIN="${PYTHON_BIN}"
}

ensure.managed.ansible() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ -x "${ANSIBLE_VENV_BIN}" ]]; then
    if "${ANSIBLE_VENV_BIN}" --version 2>/dev/null | head -n1 | grep -q 'core 2\.19\.'; then
      log "Using existing managed Ansible: $("${ANSIBLE_VENV_BIN}" --version | head -n1)"
      return
    fi
    log "Existing managed Ansible is out of policy; rebuilding venv..."
    rm -rf "${ANSIBLE_VENV}"
  fi

  ensure.python312
  log "Creating managed Ansible venv..."
  mkdir -p "${ANSIBLE_VENV}"
  "${PYTHON_BOOTSTRAP_BIN}" -m venv "${ANSIBLE_VENV}"
  "${ANSIBLE_VENV}/bin/pip" install --upgrade pip setuptools wheel
  "${ANSIBLE_VENV}/bin/pip" install --upgrade "${ANSIBLE_CORE_SPEC}" passlib
  "${ANSIBLE_VENV}/bin/ansible-galaxy" collection install community.general:8.6.0
  log "Managed Ansible ready: $("${ANSIBLE_VENV_BIN}" --version | head -n1)"
}

fetch.playlist() {
  mkdir -p "${TMP_DIR}"
  log "Fetching playlist: ${PLAYLIST_URL}"
  if ! wget -qO "${PLAYLIST_PATH}" "${PLAYLIST_URL}"; then
    log.error "Failed to fetch playlist: ${PLAYLIST_URL}"
    exit 1
  fi
  if [[ ! -s "${PLAYLIST_PATH}" ]]; then
    log.error "Playlist is empty: ${PLAYLIST_URL}"
    exit 1
  fi
}

fetch.groupvars() {
  mkdir -p "${GROUP_VARS_DIR}"
  log "Fetching base group_vars: ${BASE_GROUP_VARS_URL}"
  if ! wget -qO "${BASE_GROUP_VARS_PATH}" "${BASE_GROUP_VARS_URL}"; then
    log.error "Failed to fetch base group_vars: ${BASE_GROUP_VARS_URL}"
    exit 1
  fi
  if [[ ! -s "${BASE_GROUP_VARS_PATH}" ]]; then
    log.error "Base group_vars is empty: ${BASE_GROUP_VARS_URL}"
    exit 1
  fi

  log "Fetching trixie group_vars: ${TRIXIE_GROUP_VARS_URL}"
  if ! wget -qO "${TRIXIE_GROUP_VARS_PATH}" "${TRIXIE_GROUP_VARS_URL}"; then
    log.error "Failed to fetch trixie group_vars: ${TRIXIE_GROUP_VARS_URL}"
    exit 1
  fi
  if [[ ! -s "${TRIXIE_GROUP_VARS_PATH}" ]]; then
    log.error "Trixie group_vars is empty: ${TRIXIE_GROUP_VARS_URL}"
    exit 1
  fi

  log "Fetching release group_vars: ${GROUP_VARS_URL}"
  if ! wget -qO "${GROUP_VARS_PATH}" "${GROUP_VARS_URL}"; then
    log.error "Failed to fetch release group_vars: ${GROUP_VARS_URL}"
    exit 1
  fi
  if [[ ! -s "${GROUP_VARS_PATH}" ]]; then
    log.error "Release group_vars is empty: ${GROUP_VARS_URL}"
    exit 1
  fi
}

merge.groupvars() {
  log "Merging group_vars (base + trixie + release)..."
  if ! python3 - <<'PY' >/dev/null 2>&1
import yaml
PY
  then
    log "Installing python3-yaml for merge support..."
    apt-get update -y
    apt-get install -y --no-install-recommends python3-yaml
  fi

  python3 - "$BASE_GROUP_VARS_PATH" "$TRIXIE_GROUP_VARS_PATH" "$GROUP_VARS_PATH" "$MERGED_GROUP_VARS_PATH" <<'PY'
import sys, yaml, os

def merge(a, b):
    if not isinstance(a, dict) or not isinstance(b, dict):
        return b
    out = dict(a)
    for k, v in b.items():
        if k in out:
            out[k] = merge(out[k], v)
        else:
            out[k] = v
    return out

paths = sys.argv[1:-1]
dest = sys.argv[-1]
merged = {}
for path in paths:
    with open(path, 'r') as fh:
        data = yaml.safe_load(fh) or {}
    if data is None:
        data = {}
    if not isinstance(data, dict):
        raise SystemExit(f"{path} did not parse to a mapping")
    merged = merge(merged, data)

with open(dest, 'w') as fh:
    yaml.safe_dump(merged, fh, default_flow_style=False)
PY
  log "Merged group_vars written to ${MERGED_GROUP_VARS_PATH}"
}

fetch.playbook() {
  local name="$1"
  local url dest

  if [[ "${name}" == debian/* ]]; then
    url="${DEBIAN_BASE_URL}/${name#debian/}"
    dest="${TMP_DIR}/debian/${name#debian/}"
  elif [[ "${name}" == dell/* ]]; then
    url="${DELL_BASE_URL}/${name#dell/}"
    dest="${TMP_DIR}/dell/${name#dell/}"
  else
    url="${BASE_URL}/${name}"
    dest="${TMP_DIR}/${name}"
  fi

  mkdir -p "$(dirname "${dest}")"
  log "Fetching playbook: ${url}"
  if ! wget -qO "${dest}" "${url}"; then
    log.error "Failed to fetch playbook: ${url}"
    exit 1
  fi
  if [[ ! -s "${dest}" ]]; then
    log.error "Playbook is empty: ${url}"
    exit 1
  fi
}

run.playlist() {
  log "Running 9.1 playlist via ansible..."
  local ansible_bin="${ANSIBLE_VENV_BIN}"
  local extra_vars_args=("-e" "@${MERGED_GROUP_VARS_PATH}")
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    line="$(printf '%s' "${line}" | sed 's/[[:space:]]*$//')"
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" != *.yml ]] && continue
    fetch.playbook "${line}"

    if ! "${ansible_bin}" -i localhost, -c local "${extra_vars_args[@]}" "${TMP_DIR}/${line}"; then
      log.error "Ansible failed on playbook: ${line}"
      exit 1
    fi
  done < "${PLAYLIST_PATH}"
  log "Ansible playlist complete."
}

maybe.run.ansible() {
  if [[ "${SKIP_ANSIBLE:-0}" == "1" ]]; then
    log "SKIP_ANSIBLE=1 set; skipping ansible playlist."
    return
  fi
  ensure.managed.ansible
  fetch.playlist
  fetch.groupvars
  merge.groupvars
  run.playlist
}

main() {
  require.root
  require.apt
  require.pve9_or_trixie
  prepare.trixie.sources
  maybe.run.ansible
}

main "$@"
