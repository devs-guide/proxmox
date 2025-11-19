#!/usr/bin/env bash
## Base tooling / Ansible prerequisites installation

set -euo pipefail

BOOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "${BOOT_DIR}/packages.lib.sh"

log "--- system.base_packages: START ---"
install_base_packages
log "--- system.base_packages: DONE ---"
