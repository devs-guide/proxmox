#!/usr/bin/env bash
## Add explicit HTTP(S) egress approvals inside the ingest LXC.

set -euo pipefail
log() { printf '[setup.lxc.egress] %s\n' "$*" >&2; }
die() { printf '[setup.lxc.egress][error] %s\n' "$*" >&2; exit 1; }

MODE="${1:-${PROXMOX_LXC_EGRESS_MODE:-preflight}}"
INTERACTIVE="${PROXMOX_LXC_EGRESS_INTERACTIVE:-1}"
EGRESS_IF="${PROXMOX_LXC_EGRESS_INTERFACE:-}"
URLS="${PROXMOX_LXC_EGRESS_URLS:-}"
IPS="${PROXMOX_LXC_EGRESS_IPS:-}"
CONFIG_DIR="${PROXMOX_LXC_EGRESS_CONFIG_DIR:-/etc/proxmox-ingest}"
CONFIG_PATH="${CONFIG_DIR}/egress.allow"
FETCH_PATH="/usr/local/sbin/ingest-fetch"
OPEN_TTY=0

is_true() { case "${1,,}" in 1|true|yes|y|on) return 0 ;; *) return 1 ;; esac; }
open_tty() { [[ -r /dev/tty ]] || return 1; exec 3<>/dev/tty; OPEN_TTY=1; }
prompt() {
  local label="$1" default="${2:-}" answer=""
  if [[ -n "${default}" ]]; then printf '%s [%s]: ' "${label}" "${default}" >&3; else printf '%s: ' "${label}" >&3; fi
  read -r -u 3 answer || true
  printf '%s\n' "${answer:-${default}}"
}

url_parts() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse
p = urlparse(sys.argv[1])
if p.scheme not in {"http", "https"} or not p.hostname or p.username or p.password:
    raise SystemExit(1)
print(p.hostname)
print(p.port or (443 if p.scheme == "https" else 80))
PY
}

valid_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    value = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if value.version == 4 else 1)
PY
}

write_fetch_wrapper() {
  local temp_file
  temp_file="$(mktemp)"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'config=%q\n' "${CONFIG_PATH}"
    printf '%s\n' 'url="${1:-}"' 'output="${2:-}"' '[[ -n "${url}" ]] || { echo "usage: ingest-fetch URL [OUTPUT]" >&2; exit 2; }'
    printf '%s\n' 'allowed=0' 'while IFS= read -r line; do' '  [[ "${line}" == URL=* ]] || continue' '  prefix="${line#URL=}"' '  [[ "${url}" == "${prefix}"* ]] && { allowed=1; break; }' 'done < "${config}"'
    printf '%s\n' '((allowed == 1)) || { echo "URL is not approved by ${config}" >&2; exit 3; }'
    printf '%s\n' 'if [[ -n "${output}" ]]; then exec curl --fail --max-redirs 0 --proto "=http,https" --output "${output}" "${url}"; fi' 'exec curl --fail --max-redirs 0 --proto "=http,https" --remote-name "${url}"'
  } > "${temp_file}"
  install -m 0755 "${temp_file}" "${FETCH_PATH}"
  rm -f "${temp_file}"
}

remove_managed_rules() {
  local number
  local -a numbers=()
  mapfile -t numbers < <(
    ufw status numbered 2>/dev/null \
      | awk '/# ingest-egress/ {line=$0; sub(/^\[/, "", line); sub(/\].*$/, "", line); gsub(/[[:space:]]/, "", line); print line}' \
      | sort -rn
  )
  for number in "${numbers[@]}"; do
    [[ "${number}" =~ ^[0-9]+$ ]] || continue
    ufw --force delete "${number}"
  done
}

main() {
  local url host port ip resolved confirmation rule parsed
  local -a parts=() rules=() config_lines=()
  [[ "$(id -u)" -eq 0 ]] || die 'Run as root inside the ingest LXC.'
  [[ ! -d /etc/pve ]] && ! command -v pveversion >/dev/null 2>&1 || die 'Run inside the LXC, not on the Proxmox host.'
  case "${MODE}" in preflight|apply|revoke) ;; *) die 'Mode must be preflight, apply, or revoke.' ;; esac
  command -v python3 >/dev/null 2>&1 || die 'python3 is required.'
  command -v ufw >/dev/null 2>&1 || die 'ufw is required; run setup/lxc/samba.sh first.'
  EGRESS_IF="${EGRESS_IF:-$(ip route show default | awk 'NR==1 {print $5}')}"
  [[ -n "${EGRESS_IF}" ]] && ip link show dev "${EGRESS_IF}" >/dev/null 2>&1 || die 'Unable to discover the egress interface.'
  if [[ "${MODE}" == revoke ]]; then
    if is_true "${INTERACTIVE}" && open_tty; then
      confirmation="$(prompt 'Type yes to revoke all managed HTTP(S) egress approvals' 'no')"
      [[ "${confirmation}" == yes ]] || die 'Operator aborted.'
    fi
    remove_managed_rules
    rm -f -- "${CONFIG_PATH}" "${FETCH_PATH}"
    log 'All managed HTTP(S) egress approvals were revoked; default-deny remains active.'
    return 0
  fi
  if is_true "${INTERACTIVE}" && open_tty; then
    URLS="$(prompt 'Approved HTTP(S) URL prefixes (space separated)' "${URLS}")"
    IPS="$(prompt 'Additional approved IPv4 addresses (space separated)' "${IPS}")"
  fi
  [[ -n "${URLS}" || -n "${IPS}" ]] || die 'At least one URL prefix or IPv4 address is required.'

  for url in ${URLS}; do
    parsed="$(url_parts "${url}")" || die "Invalid URL: ${url}"
    mapfile -t parts <<< "${parsed}"
    host="${parts[0]}"; port="${parts[1]}"; config_lines+=("URL=${url}")
    while IFS= read -r resolved; do [[ -n "${resolved}" ]] && rules+=("${resolved}|${port}|${host}"); done \
      < <(getent ahostsv4 "${host}" | awk '{print $1}' | sort -u)
  done
  for ip in ${IPS}; do
    valid_ipv4 "${ip}" || die "Invalid IPv4 address: ${ip}"
    config_lines+=("IP=${ip}"); rules+=("${ip}|80|explicit-ip" "${ip}|443|explicit-ip")
  done
  ((${#rules[@]} > 0)) || die 'No approved destination resolved to IPv4.'
  printf '\nOutbound approval plan on %s:\n' "${EGRESS_IF}" >&2; printf '  %s\n' "${rules[@]}" >&2
  [[ "${MODE}" == apply ]] || { log 'Preflight complete; no firewall change made.'; return; }
  if is_true "${INTERACTIVE}" && ((OPEN_TTY == 1)); then
    confirmation="$(prompt 'Type yes to apply these UFW rules' 'no')"; [[ "${confirmation}" == yes ]] || die 'Operator aborted.'
  fi
  install -d -m 0750 "${CONFIG_DIR}"
  umask 027
  { printf 'EGRESS_INTERFACE=%s\n' "${EGRESS_IF}"; printf '%s\n' "${config_lines[@]}"; printf 'RESOLVED=%s\n' "${rules[@]}"; } > "${CONFIG_PATH}"
  chmod 0640 "${CONFIG_PATH}"
  remove_managed_rules
  for rule in "${rules[@]}"; do
    IFS='|' read -r ip port host <<< "${rule}"
    ufw allow out on "${EGRESS_IF}" to "${ip}" port "${port}" proto tcp comment "ingest-egress"
  done
  write_fetch_wrapper
  ufw --force enable
  log "Approvals installed; use ${FETCH_PATH} for downloads."
}

main "$@"
