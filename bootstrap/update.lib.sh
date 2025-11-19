#!/usr/bin/env bash
## Update / upgrade functions

BOOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "${BOOT_DIR}/common.core.sh"

apt_update_upgrade() {
  log "Updating package index..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update

  if [[ "${DO_FULL_UPGRADE}" -eq 1 ]]; then
    log "Running apt-get full-upgrade (non-interactive)..."
    apt-get -y full-upgrade
  else
    log "SKIP: full-upgrade (DO_FULL_UPGRADE=0)."
  fi
}
