#!/usr/bin/env bash
## System identity setup (hostname, /etc/hosts)

set -euo pipefail

BOOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "${BOOT_DIR}/identity.lib.sh"

log "--- system.identity: START ---"
set_hostname "${HOSTNAME_NEW}"
log "--- system.identity: DONE ---"
