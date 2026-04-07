#!/usr/bin/env bash
## Bootstrap Proxmox VE 6.4 (Buster) repair + ansible playlist runner.
## Usage:
##   wget -qO- https://devs-guide.github.io/proxmox/6.4.sh | bash

set -euo pipefail

log()      { printf '[pve-6.4] %s\n' "$*" >&2; }
log.error(){ printf '[pve-6.4][error] %s\n' "$*" >&2; }

TMP_DIR="/tmp/pve-6.4"
BASE_URL="https://devs-guide.github.io/proxmox/ansible/release/6.4"
DEBIAN_BASE_URL="https://devs-guide.github.io/proxmox/ansible/debian"
PLAYLIST="install.playbooks.txt"
PLAYLIST_URL="${BASE_URL}/${PLAYLIST}"
PLAYLIST_PATH="${TMP_DIR}/${PLAYLIST}"
GROUP_VARS_DIR="${TMP_DIR}/group_vars"
BASE_GROUP_VARS_FILE="base.yml"
GROUP_VARS_FILE="all.yml"
BASE_GROUP_VARS_URL="https://devs-guide.github.io/proxmox/ansible/group_vars/all.yml"
GROUP_VARS_URL="${BASE_URL}/group_vars/${GROUP_VARS_FILE}"
BASE_GROUP_VARS_PATH="${GROUP_VARS_DIR}/${BASE_GROUP_VARS_FILE}"
GROUP_VARS_PATH="${GROUP_VARS_DIR}/${GROUP_VARS_FILE}"

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

ensure.ansible.venv() {
  # Minimal bootstrap: ensure ansible-playbook exists (can be old); playbook.yml will enforce modern venv
  if command -v ansible-playbook >/dev/null 2>&1; then
    log "Using existing system Ansible: $(ansible-playbook --version | head -n1)"
    return
  fi

  log "Installing ansible from distro (temporary control)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends ansible python3-apt
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

fetch.playbook() {
  local name="$1"
  local url dest

  if [[ "${name}" == debian/* ]]; then
    url="${DEBIAN_BASE_URL}/${name#debian/}"
    dest="${TMP_DIR}/debian/${name#debian/}"
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
  log "Running 6.4 playlist via ansible..."
  local ansible_bin="ansible-playbook"
  local extra_vars_args=(-e "@${BASE_GROUP_VARS_PATH}" -e "@${GROUP_VARS_PATH}")
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
  ensure.ansible.venv
  fetch.playlist
  fetch.groupvars
  run.playlist
}

main() {
  require.root
  require.apt
  require.pve6
  maybe.run.ansible
}

main "$@"
