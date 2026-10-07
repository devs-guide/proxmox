#!/usr/bin/env bash
## Physical DATA-Link discovery and activation for a Proxmox SMB local LAN.
## Local usage:
##   ./setup/network-link.sh [preflight|up]
## Published usage:
##   wget -qO- https://devs-guide.github.io/proxmox/setup/network-link.sh | bash -s -- preflight

set -euo pipefail

log()       { printf '[setup.network-link] %s\n' "$*" >&2; }
log.error() { printf '[setup.network-link][error] %s\n' "$*" >&2; }

MODE="${1:-${PROXMOX_NETWORK_LINK_MODE:-preflight}}"
TMP_DIR="/tmp/pve-feature-network-link"
PAGES_BASE_URL="https://devs-guide.github.io/proxmox"
LOCAL_COMMON_HELPER="../bootstrap/release.common.sh"
COMMON_HELPER_URL="${PAGES_BASE_URL}/release.common.sh"
COMMON_HELPER_PATH="${TMP_DIR}/release.common.sh"
FACTS_DIR="${PROXMOX_NETWORK_LINK_FACTS_DIR:-/etc/ansible/proxmox/facts}"
SELECTION_PATH="${PROXMOX_NETWORK_LINK_SELECTION_PATH:-${FACTS_DIR}/network-link.selection.yml}"
READY_PATH="${PROXMOX_NETWORK_LINK_READY_PATH:-${FACTS_DIR}/network-link.ready.yml}"
SELECTED_NIC="${PROXMOX_NETWORK_LINK_NIC:-}"
EXPECTED_PCI="${PROXMOX_NETWORK_LINK_EXPECTED_PCI:-}"
EXPECTED_MAC="${PROXMOX_NETWORK_LINK_EXPECTED_MAC:-}"
EXPECTED_BRIDGE="${PROXMOX_NETWORK_LINK_EXPECTED_BRIDGE:-}"
MIN_SPEED_MBPS="${PROXMOX_NETWORK_LINK_MIN_SPEED_MBPS:-1000}"
WAIT_SECONDS="${PROXMOX_NETWORK_LINK_WAIT_SECONDS:-8}"
FEATURE_INTERACTIVE="${PROXMOX_NETWORK_LINK_INTERACTIVE:-1}"
CONFIRM_UP="${PROXMOX_NETWORK_LINK_CONFIRM_UP:-}"
MGMT_BRIDGE=""
MGMT_NICS=""

source.release.common() {
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  if [[ -n "${script_dir}" && -r "${script_dir}/${LOCAL_COMMON_HELPER}" ]]; then
    # shellcheck source=bootstrap/release.common.sh
    source "${script_dir}/${LOCAL_COMMON_HELPER}"
    return
  fi
  mkdir -p "${TMP_DIR}"
  log "Fetching shared bootstrap helper: ${COMMON_HELPER_URL}"
  wget -qO "${COMMON_HELPER_PATH}" "${COMMON_HELPER_URL}"
  [[ -s "${COMMON_HELPER_PATH}" ]] || {
    log.error "Shared bootstrap helper is empty: ${COMMON_HELPER_URL}"
    exit 1
  }
  # shellcheck source=/tmp/pve-feature-network-link/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

source.release.common

is.true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

yaml.quote() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

open.tty() {
  [[ -r /dev/tty ]] || return 1
  exec 3<>/dev/tty
}

menu.tty() {
  local prompt="$1" answer="" i
  shift
  local -a options=("$@")
  while true; do
    printf '%s\n' "${prompt}" >&3
    for i in "${!options[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${options[$i]}" >&3
    done
    printf 'Select option: ' >&3
    read -r -u 3 answer || true
    if [[ "${answer}" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#options[@]})); then
      printf '%s\n' "${answer}"
      return
    fi
    printf 'Invalid selection.\n' >&3
  done
}

require.commands() {
  local command_name
  for command_name in ip ethtool awk sed readlink basename; do
    command -v "${command_name}" >/dev/null 2>&1 || {
      log.error "Missing required command: ${command_name}"
      exit 1
    }
  done
  command -v pveversion >/dev/null 2>&1 || {
    log.error "This runner must execute on a Proxmox host."
    exit 1
  }
  [[ "${MODE}" == preflight || "${MODE}" == up ]] || {
    log.error "Unsupported mode ${MODE}; use preflight or up."
    exit 1
  }
  [[ "${MIN_SPEED_MBPS}" =~ ^[0-9]+$ ]] && ((MIN_SPEED_MBPS >= 1000)) || {
    log.error "PROXMOX_NETWORK_LINK_MIN_SPEED_MBPS must be an integer of at least 1000."
    exit 1
  }
  [[ "${WAIT_SECONDS}" =~ ^[0-9]+$ ]] && ((WAIT_SECONDS >= 1 && WAIT_SECONDS <= 60)) || {
    log.error "PROXMOX_NETWORK_LINK_WAIT_SECONDS must be between 1 and 60."
    exit 1
  }
}

discover.management.path() {
  local route_dev="" port=""
  route_dev="$(ip route show default 2>/dev/null | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
  [[ -n "${route_dev}" ]] || {
    log.error "No default-route interface was discovered."
    exit 1
  }
  MGMT_BRIDGE="${route_dev}"
  if [[ -L "/sys/class/net/${route_dev}/master" ]]; then
    MGMT_BRIDGE="$(basename "$(readlink -f "/sys/class/net/${route_dev}/master")")"
  fi
  MGMT_NICS=""
  if [[ -d "/sys/class/net/${MGMT_BRIDGE}/brif" ]]; then
    for port in "/sys/class/net/${MGMT_BRIDGE}"/brif/*; do
      [[ -e "${port}" ]] || continue
      [[ -e "/sys/class/net/$(basename "${port}")/device" ]] || continue
      MGMT_NICS="${MGMT_NICS}${MGMT_NICS:+,}$(basename "${port}")"
    done
  elif [[ -e "/sys/class/net/${route_dev}/device" ]]; then
    MGMT_NICS="${route_dev}"
  fi
}

nic.pci() { basename "$(readlink -f "/sys/class/net/$1/device")"; }
nic.mac() { cat "/sys/class/net/$1/address" 2>/dev/null || true; }
nic.permanent.mac() {
  local value
  value="$(ethtool -P "$1" 2>/dev/null | awk '{print $3}' || true)"
  case "${value}" in ''|00:00:00:00:00:00|not|set) value="" ;; esac
  printf '%s\n' "${value}"
}
nic.master() {
  if [[ -L "/sys/class/net/$1/master" ]]; then
    basename "$(readlink -f "/sys/class/net/$1/master")"
  fi
}
nic.ipv4() { ip -o -4 addr show dev "$1" 2>/dev/null | awk 'NR == 1 {print $4}'; }
nic.admin.state() {
  if ip -o link show dev "$1" 2>/dev/null | grep -q '<[^>]*UP'; then printf 'up\n'; else printf 'down\n'; fi
}
nic.carrier() {
  local value
  value="$(cat "/sys/class/net/$1/carrier" 2>/dev/null || true)"
  [[ "${value}" == 0 || "${value}" == 1 ]] || value="unknown"
  printf '%s\n' "${value}"
}
nic.speed() {
  local value
  value="$(cat "/sys/class/net/$1/speed" 2>/dev/null || true)"
  [[ "${value}" =~ ^[0-9]+$ ]] || value="unknown"
  printf '%s\n' "${value}"
}
nic.supported.speed() {
  local value
  value="$(ethtool "$1" 2>/dev/null | awk '
    /Supported link modes:/ {inside=1}
    /Advertised link modes:/ {inside=0}
    inside {
      for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+base/) {
        split($i, part, "base"); if ((part[1] + 0) > max) max=part[1] + 0
      }
    }
    END {if (max > 0) print max}
  ')"
  [[ "${value}" =~ ^[0-9]+$ ]] || value="unknown"
  printf '%s\n' "${value}"
}

is.management.nic() {
  local item
  IFS=',' read -r -a items <<< "${MGMT_NICS}"
  for item in "${items[@]}"; do [[ "$1" == "${item}" ]] && return 0; done
  return 1
}

load.persisted.selection() {
  [[ -r "${SELECTION_PATH}" ]] || return 1
  [[ -n "${SELECTED_NIC}" ]] || SELECTED_NIC="$(sed -n 's/^[[:space:]]*nic:[[:space:]]*"\{0,1\}\([^" ]*\)"\{0,1\}[[:space:]]*$/\1/p' "${SELECTION_PATH}" | head -n1)"
  [[ -n "${EXPECTED_PCI}" ]] || EXPECTED_PCI="$(sed -n 's/^[[:space:]]*expected_pci:[[:space:]]*"\{0,1\}\([^" ]*\)"\{0,1\}[[:space:]]*$/\1/p' "${SELECTION_PATH}" | head -n1)"
  [[ -n "${EXPECTED_MAC}" ]] || EXPECTED_MAC="$(sed -n 's/^[[:space:]]*expected_mac:[[:space:]]*"\{0,1\}\([^" ]*\)"\{0,1\}[[:space:]]*$/\1/p' "${SELECTION_PATH}" | head -n1)"
  [[ -n "${SELECTED_NIC}" ]]
}

choose.nic.interactive() {
  local -a options=() names=()
  local path nic ip member supported choice
  for path in /sys/class/net/*; do
    [[ -e "${path}/device" ]] || continue
    nic="$(basename "${path}")"
    is.management.nic "${nic}" && continue
    ip="$(nic.ipv4 "${nic}")"
    member="$(nic.master "${nic}")"
    supported="$(nic.supported.speed "${nic}")"
    [[ -z "${ip}" ]] || continue
    [[ -z "${member}" || "${member}" == "${EXPECTED_BRIDGE}" ]] || continue
    [[ "${supported}" =~ ^[0-9]+$ ]] && ((supported >= MIN_SPEED_MBPS)) || continue
    names+=("${nic}")
    options+=("${nic} | capability=${supported}Mbps | admin=$(nic.admin.state "${nic}") | carrier=$(nic.carrier "${nic}") | bridge=${member:-none} | pci=$(nic.pci "${nic}")")
  done
  options+=("abort")
  ((${#names[@]} > 0)) || {
    log.error "No separate physical DATA-Link NIC satisfies the ${MIN_SPEED_MBPS}Mbps policy."
    exit 1
  }
  choice="$(menu.tty "Select the physical DATA-Link NIC:" "${options[@]}")"
  ((choice <= ${#names[@]})) || { log.error "Operator aborted NIC selection."; exit 1; }
  SELECTED_NIC="${names[$((choice - 1))]}"
}

validate.selection() {
  local actual_pci actual_mac permanent_mac ip member supported
  [[ -n "${SELECTED_NIC}" && -e "/sys/class/net/${SELECTED_NIC}/device" ]] || {
    log.error "Selected DATA-Link NIC is missing or is not a physical interface: ${SELECTED_NIC:-none}"
    exit 1
  }
  is.management.nic "${SELECTED_NIC}" && {
    log.error "Selected DATA-Link NIC belongs to the management path."
    exit 1
  }
  actual_pci="$(nic.pci "${SELECTED_NIC}")"
  actual_mac="$(nic.mac "${SELECTED_NIC}")"
  permanent_mac="$(nic.permanent.mac "${SELECTED_NIC}")"
  if [[ -n "${EXPECTED_PCI}" && "${EXPECTED_PCI}" != "-" && "${actual_pci}" != "${EXPECTED_PCI}" ]]; then
    log.error "Selected NIC PCI identity changed: expected ${EXPECTED_PCI}, found ${actual_pci}."
    exit 1
  fi
  if [[ -n "${EXPECTED_MAC}" && "${EXPECTED_MAC}" != "-" \
    && "${actual_mac,,}" != "${EXPECTED_MAC,,}" && "${permanent_mac,,}" != "${EXPECTED_MAC,,}" ]]; then
    log.error "Selected NIC MAC identity changed."
    exit 1
  fi
  EXPECTED_PCI="${actual_pci}"
  EXPECTED_MAC="${permanent_mac:-${actual_mac}}"
  ip="$(nic.ipv4 "${SELECTED_NIC}")"
  [[ -z "${ip}" ]] || { log.error "Selected DATA-Link NIC already has host IPv4 ${ip}."; exit 1; }
  member="$(nic.master "${SELECTED_NIC}")"
  [[ -z "${member}" || "${member}" == "${EXPECTED_BRIDGE}" ]] || {
    log.error "Selected DATA-Link NIC belongs to foreign bridge ${member}."
    exit 1
  }
  supported="$(nic.supported.speed "${SELECTED_NIC}")"
  [[ "${supported}" =~ ^[0-9]+$ ]] && ((supported >= MIN_SPEED_MBPS)) || {
    log.error "Selected NIC capability ${supported}Mbps does not satisfy the ${MIN_SPEED_MBPS}Mbps policy."
    exit 1
  }
}

write.selection() {
  mkdir -p "${FACTS_DIR}"
  cat > "${SELECTION_PATH}" <<EOF
---
proxmox_network_link_selection:
  confirmed: true
  nic: $(yaml.quote "${SELECTED_NIC}")
  expected_pci: $(yaml.quote "${EXPECTED_PCI}")
  expected_mac: $(yaml.quote "${EXPECTED_MAC}")
  expected_bridge: $(yaml.quote "${EXPECTED_BRIDGE}")
  minimum_speed_mbps: ${MIN_SPEED_MBPS}
EOF
  log "Persisted DATA-Link selection: ${SELECTION_PATH}"
}

bring.link.up() {
  local state carrier speed attempt choice
  state="$(nic.admin.state "${SELECTED_NIC}")"
  carrier="$(nic.carrier "${SELECTED_NIC}")"
  log "DATA-Link status: nic=${SELECTED_NIC} admin=${state} carrier=${carrier} speed=$(nic.speed "${SELECTED_NIC}")Mbps"
  if [[ "${state}" != up ]]; then
    if is.true "${FEATURE_INTERACTIVE}" && open.tty; then
      choice="$(menu.tty "${SELECTED_NIC} is administratively down. Bring up this DATA-Link now?" "yes" "abort")"
      [[ "${choice}" == 1 ]] || { log.error "Operator declined DATA-Link activation."; exit 1; }
    elif [[ "${CONFIRM_UP}" != YES ]]; then
      log.error "Non-interactive activation requires PROXMOX_NETWORK_LINK_CONFIRM_UP=YES."
      exit 1
    fi
    ip link set dev "${SELECTED_NIC}" up
    log "Brought ${SELECTED_NIC} administratively up; waiting for physical carrier."
  fi
  carrier="$(nic.carrier "${SELECTED_NIC}")"
  for ((attempt=0; attempt<WAIT_SECONDS; attempt++)); do
    [[ "${carrier}" == 1 ]] && break
    sleep 1
    carrier="$(nic.carrier "${SELECTED_NIC}")"
  done
  if [[ "${carrier}" != 1 ]]; then
    log.error "${SELECTED_NIC} is administratively up, but no physical carrier was detected."
    log.error "Attach the Ethernet cable and enable the peer switch/network port, then rerun this command."
    exit 1
  fi
  speed="$(nic.speed "${SELECTED_NIC}")"
  [[ "${speed}" =~ ^[0-9]+$ ]] && ((speed >= MIN_SPEED_MBPS)) || {
    log.error "Physical carrier is present, but negotiated speed ${speed}Mbps is below the ${MIN_SPEED_MBPS}Mbps policy."
    exit 1
  }
  mkdir -p "${FACTS_DIR}"
  cat > "${READY_PATH}" <<EOF
---
proxmox_network_link_ready:
  ready: true
  boot_id: $(yaml.quote "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)")
  nic: $(yaml.quote "${SELECTED_NIC}")
  expected_pci: $(yaml.quote "${EXPECTED_PCI}")
  expected_mac: $(yaml.quote "${EXPECTED_MAC}")
  expected_bridge: $(yaml.quote "${EXPECTED_BRIDGE}")
  carrier: true
  negotiated_speed_mbps: ${speed}
  minimum_speed_mbps: ${MIN_SPEED_MBPS}
EOF
  log "DATA-Link ready: nic=${SELECTED_NIC} carrier=present negotiated_speed=${speed}Mbps"
}

main() {
  require.root
  require.commands
  discover.management.path
  load.persisted.selection || true
  if [[ -z "${SELECTED_NIC}" ]]; then
    if is.true "${FEATURE_INTERACTIVE}" && open.tty; then
      choose.nic.interactive
    else
      log.error "Set PROXMOX_NETWORK_LINK_NIC when interactive selection is unavailable."
      exit 1
    fi
  fi
  validate.selection
  write.selection
  log "DATA-Link preflight: nic=${SELECTED_NIC} admin=$(nic.admin.state "${SELECTED_NIC}") carrier=$(nic.carrier "${SELECTED_NIC}") capability=$(nic.supported.speed "${SELECTED_NIC}")Mbps"
  [[ "${MODE}" == up ]] && bring.link.up
}

main "$@"
