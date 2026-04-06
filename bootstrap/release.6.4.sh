#!/usr/bin/env bash
## Fix apt on Proxmox VE 6.4 (EOL Buster) so updates work again.
## Usage:
##   wget -qO- https://devs-guide.github.io/proxmox/6.4.sh | bash

set -euo pipefail

log()      { printf '[pve-6.4] %s\n' "$*" >&2; }
log.error(){ printf '[pve-6.4][error] %s\n' "$*" >&2; }

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
deb http://download.proxmox.com/debian/pve buster pve-no-subscription
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

main() {
  require.root
  require.apt
  require.pve6
  write.sources.list
  write.apt.conf.archive
  disable.enterprise.repo
  write.no.subscription
  run.update
}

main "$@"
