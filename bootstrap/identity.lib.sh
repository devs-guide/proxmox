#!/usr/bin/env bash
## Identity-related functions (hostname, /etc/hosts)

BOOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "${BOOT_DIR}/common.core.sh"

set_hostname() {
  local new_host="$1"

  if [[ -z "$new_host" ]]; then
    log "SKIP: HOSTNAME_NEW is empty, not changing hostname."
    return
  fi

  log "Setting hostname to: ${new_host}"

  echo "${new_host}" > /etc/hostname

  # Ensure /etc/hosts has sane loopback + 127.0.1.1
  if ! grep -qE '^127\.0\.0\.1\s+localhost' /etc/hosts; then
    echo -e "127.0.0.1\tlocalhost" >> /etc/hosts
  fi

  if grep -qE '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${new_host}/" /etc/hosts
  else
    echo -e "127.0.1.1\t${new_host}" >> /etc/hosts
  fi

  hostnamectl set-hostname "${new_host}" || true
}
