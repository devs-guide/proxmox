#!/usr/bin/env bash
## OpenSSH transport wrapper for the restricted LXC rsync service.

set -euo pipefail

CONFIG_DIR="${PROXMOX_LXC_TRANSFER_CONFIG_DIR:-/etc/proxmox-transfer}"
IDENTITY_FILE="${PROXMOX_LXC_TRANSFER_IDENTITY_FILE:-${CONFIG_DIR}/id_ed25519}"
KNOWN_HOSTS_FILE="${PROXMOX_LXC_TRANSFER_KNOWN_HOSTS_FILE:-${CONFIG_DIR}/known_hosts}"
SELECTION_PATH="${PROXMOX_LXC_TRANSFER_SELECTION_PATH:-/etc/ansible/proxmox/facts/lxc.transfer.selection.yml}"

die() { printf '[proxmox-transfer-ssh][error] %s\n' "$*" >&2; exit 1; }

(($# > 0)) || die 'This is an rsync SSH transport wrapper; invoke it through proxmox-transfer-rsync or rsync -e.'
[[ -r "${IDENTITY_FILE}" ]] || die "Missing transfer identity: ${IDENTITY_FILE}"
[[ -r "${KNOWN_HOSTS_FILE}" ]] || die "Missing pinned peer host keys: ${KNOWN_HOSTS_FILE}"
[[ -r "${SELECTION_PATH}" ]] || die "Missing transfer selection: ${SELECTION_PATH}"
command -v python3 >/dev/null 2>&1 || die 'python3 is required.'

selection="$(python3 - "${SELECTION_PATH}" <<'PY'
import ipaddress, json, pathlib, re, sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())["proxmox_lxc_transfer_operator_selection"]
interface = ipaddress.ip_interface(data["local_cidr"])
allowed = ipaddress.ip_network(data["allow_cidr"], strict=False)
user = str(data["service_user"])
port = int(data["port"])
if (interface.network != allowed or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,30}", user)
        or not 1 <= port <= 65535):
    raise SystemExit(1)
print(user)
print(port)
print(interface.ip)
print(allowed)
PY
)" || die 'Saved transfer selection is invalid.'
mapfile -t selected <<< "${selection}"
[[ ${#selected[@]} -eq 4 ]] || die 'Saved transfer selection is incomplete.'
SERVICE_USER="${selected[0]}"
PORT="${selected[1]}"
LOCAL_ADDRESS="${selected[2]}"
ALLOW_CIDR="${selected[3]}"

if [[ "${1:-}" == check ]]; then
  [[ $# -eq 2 ]] || die 'usage: proxmox-transfer-ssh check PEER_IPV4'
  peer="$(python3 - "$2" "${LOCAL_ADDRESS}" "${ALLOW_CIDR}" <<'PY'
import ipaddress, sys

peer = ipaddress.IPv4Address(sys.argv[1])
local = ipaddress.IPv4Address(sys.argv[2])
allowed = ipaddress.ip_network(sys.argv[3], strict=False)
if peer not in allowed or peer == local:
    raise SystemExit(1)
print(peer)
PY
  )" || die 'Peer must be another IPv4 address on the selected DATA-Link.'
  set -- "${SERVICE_USER}@${peer}" proxmox-transfer-check
fi

exec ssh \
  -F /dev/null \
  -i "${IDENTITY_FILE}" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" \
  -o GlobalKnownHostsFile=/dev/null \
  -o ForwardAgent=no \
  -o ClearAllForwardings=yes \
  -o RequestTTY=no \
  -p "${PORT}" \
  "$@"
