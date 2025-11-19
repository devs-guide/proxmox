#!/usr/bin/env bash
## System update / upgrade

set -euo pipefail

BOOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "${BOOT_DIR}/update.lib.sh"

log "--- system.update: START ---"
apt_update_upgrade
log "--- system.update: DONE ---"
