#!/usr/bin/env bash
## Base tooling installer helpers

BOOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "${BOOT_DIR}/common.core.sh"
# shellcheck source=/dev/null
. "${BOOT_DIR}/packages.list.sh"

install_base_packages() {
  log "Installing base admin / Ansible prerequisites..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "${BASE_PACKAGES[@]}"
}
