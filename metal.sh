#!/usr/bin/env bash
## Main bootstrap entry for bare-metal Debian

set -euo pipefail

# Resolve repo root and helper dir
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_DIR="${ROOT_DIR}/bootstrap"

# Bring in common config + helpers (require_root, setup_logging, log, etc.)
# shellcheck source=/dev/null
. "${BOOT_DIR}/common.lib.sh"

require_root
setup_logging

log "===== setup start ====="
log "DO_FULL_UPGRADE=${DO_FULL_UPGRADE} DO_REBOOT=${DO_REBOOT} LOGFILE=${LOGFILE}"
log "HOSTNAME_NEW=${HOSTNAME_NEW:-<none>}"

# Step 1 – System identity (hostname, /etc/hosts)
"${BOOT_DIR}/system.identity.sh"

# Step 2 – Update & upgrade
"${BOOT_DIR}/system.update.sh"

# Step 3 – Base tooling / Ansible prerequisites
"${BOOT_DIR}/system.base_packages.sh"

log "===== setup complete – ready for further hardening / Ansible ====="

maybe_reboot
