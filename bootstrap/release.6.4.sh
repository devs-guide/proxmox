#!/usr/bin/env bash
## Fix apt on Proxmox VE 6.4 (EOL Buster) so updates work again.
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
GROUP_VARS_FILE="all.yml"
GROUP_VARS_URL="${BASE_URL}/group_vars/${GROUP_VARS_FILE}"
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

write.sources.list() {
  log "Updating /etc/apt/sources.list to use Debian archive mirrors..."
  cat > /etc/apt/sources.list <<'EOF'
deb http://archive.debian.org/debian buster main contrib non-free
deb-src http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main contrib non-free
deb-src http://archive.debian.org/debian-security buster/updates main contrib non-free
EOF
}

write.apt.conf.archive() {
  log "Allowing archived (expired) metadata for Buster..."
  cat > /etc/apt/apt.conf.d/99-archive-buster <<'EOF'
Acquire::Check-Valid-Until "false";
Acquire::AllowInsecureRepositories "true";
EOF
}

disable.enterprise.repo() {
  local file="/etc/apt/sources.list.d/pve-enterprise.list"
  if [[ -f "${file}" ]]; then
    log "Disabling enterprise repo (${file})..."
    sed -i 's/^deb/# deb/' "${file}"
  fi
}

write.no.subscription() {
  local file="/etc/apt/sources.list.d/pve-no-subscription.list"
  log "Ensuring no-subscription repo (${file})..."
  cat > "${file}" <<'EOF'
deb http://archive.proxmox.com/debian/pve buster pve-no-subscription
EOF
}

run.update() {
  log "Running apt-get update..."
  if ! apt-get update; then
    log.error "apt-get update failed."
    exit 1
  fi

  log "Dry-run dist-upgrade (apt-get -s dist-upgrade)..."
  if ! apt-get -s dist-upgrade; then
    log.error "apt-get -s dist-upgrade failed."
    exit 1
  fi
  log "Apt sources repaired. You can now run 'apt-get dist-upgrade'."
}

maybe.install.ansible() {
  if command -v ansible-playbook >/dev/null 2>&1; then
    log "Ansible already installed: $(ansible-playbook --version | head -n1)"
    return
  fi

  log "Installing ansible (Buster archive)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends \
    ansible \
    python3-apt

  log "Ansible installed: $(ansible-playbook --version | head -n1)"
}

fetch.playlist() {
  mkdir -p "${TMP_DIR}"
  log "Fetching 6.4 playlist: ${PLAYLIST_URL}"
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
  log "Fetching 6.4 group_vars: ${GROUP_VARS_URL}"
  if ! wget -qO "${GROUP_VARS_PATH}" "${GROUP_VARS_URL}"; then
    log.error "Failed to fetch group_vars: ${GROUP_VARS_URL}"
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
}

run.playlist() {
  log "Running 6.4 playlist via ansible..."
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    line="$(printf '%s' "${line}" | sed 's/[[:space:]]*$//')"
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" != *.yml ]] && continue
    fetch.playbook "${line}"
    ansible-playbook -i localhost, -c local "${TMP_DIR}/${line}"
  done < "${PLAYLIST_PATH}"
  log "Ansible playlist complete."
}

maybe.run.ansible() {
  if [[ "${SKIP_ANSIBLE:-0}" == "1" ]]; then
    log "SKIP_ANSIBLE=1 set; skipping ansible playlist."
    return
  fi
  maybe.install.ansible
  fetch.playlist
  fetch.groupvars
  run.playlist
}

main() {
  require.root
  require.apt
  require.pve6
  write.sources.list
  write.apt.conf.archive
  disable.enterprise.repo
  write.no.subscription
  run.update
  maybe.run.ansible
}

main "$@"
