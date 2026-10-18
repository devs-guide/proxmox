#!/usr/bin/env bash
## Copy trees through the dedicated rsync-only LXC SSH service.

set -euo pipefail

ACTION="${1:-}"
SOURCE="${2:-}"
DESTINATION="${3:-}"
SSH_WRAPPER="${PROXMOX_LXC_TRANSFER_SSH_WRAPPER:-/usr/local/sbin/proxmox-transfer-ssh}"
SELECTION_PATH="${PROXMOX_LXC_TRANSFER_SELECTION_PATH:-/etc/ansible/proxmox/facts/lxc.transfer.selection.yml}"

usage() {
  printf 'usage: %s push LOCAL_PATH PEER_IPV4:RELATIVE_PATH\n       %s pull PEER_IPV4:RELATIVE_PATH LOCAL_PATH\n       %s verify-push LOCAL_PATH PEER_IPV4:RELATIVE_PATH\n       %s verify-pull PEER_IPV4:RELATIVE_PATH LOCAL_PATH\n' \
    "$0" "$0" "$0" "$0" >&2
  exit 2
}

validate.remote() {
  python3 - "$1" "${SELECTION_PATH}" <<'PY'
import ipaddress, json, pathlib, re, sys
try:
    endpoint, path = sys.argv[1].split(":", 1)
    peer = ipaddress.IPv4Address(endpoint)
except (ValueError, IndexError):
    raise SystemExit(1)
selection = json.loads(pathlib.Path(sys.argv[2]).read_text())["proxmox_lxc_transfer_operator_selection"]
allowed = ipaddress.ip_network(selection["allow_cidr"], strict=False)
local = ipaddress.ip_interface(selection["local_cidr"])
service_user = str(selection["service_user"])
if (local.network != allowed or peer not in allowed or peer == local.ip
        or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,30}", service_user)):
    raise SystemExit(1)
candidate = pathlib.PurePosixPath(path)
if path.startswith("/") or not path or ".." in candidate.parts:
    raise SystemExit(1)
print(endpoint)
print(path)
print(service_user)
PY
}

validate.local() {
  python3 - "$1" "${SELECTION_PATH}" <<'PY'
import json, pathlib, sys
candidate = pathlib.Path(sys.argv[1])
selection = json.loads(pathlib.Path(sys.argv[2]).read_text())["proxmox_lxc_transfer_operator_selection"]
root = pathlib.Path(selection["transfer_root"]).resolve(strict=True)
resolved = candidate.resolve(strict=True)
try:
    resolved.relative_to(root)
except ValueError:
    raise SystemExit(1)
if candidate.is_symlink():
    raise SystemExit(1)
PY
}

[[ "${ACTION}" == push || "${ACTION}" == pull || "${ACTION}" == verify-push || "${ACTION}" == verify-pull ]] || usage
[[ -n "${SOURCE}" && -n "${DESTINATION}" && $# -eq 3 ]] || usage
[[ -x "${SSH_WRAPPER}" ]] || { printf '[proxmox-transfer-rsync][error] Missing SSH wrapper: %s\n' "${SSH_WRAPPER}" >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { printf '[proxmox-transfer-rsync][error] rsync is required.\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf '[proxmox-transfer-rsync][error] python3 is required.\n' >&2; exit 1; }
[[ -r "${SELECTION_PATH}" ]] || { printf '[proxmox-transfer-rsync][error] Missing transfer selection: %s\n' "${SELECTION_PATH}" >&2; exit 1; }

if [[ "${ACTION}" == push || "${ACTION}" == verify-push ]]; then
  [[ -e "${SOURCE}" ]] || { printf '[proxmox-transfer-rsync][error] Local source does not exist: %s\n' "${SOURCE}" >&2; exit 1; }
  validate.local "${SOURCE}" || { printf '[proxmox-transfer-rsync][error] Local source must be within the selected transfer root.\n' >&2; exit 1; }
  parsed="$(validate.remote "${DESTINATION}")" || usage
  mapfile -t remote <<< "${parsed}"
  if [[ "${ACTION}" == verify-push ]]; then
    exec rsync -rlptHAXS --safe-links --human-readable \
      --dry-run --checksum --itemize-changes --stats \
      -e "${SSH_WRAPPER}" -- "${SOURCE}" "${remote[2]}@${remote[0]}:${remote[1]}"
  fi
  exec rsync -rlptHAXS --safe-links --partial --human-readable --info=progress2 \
    -e "${SSH_WRAPPER}" -- "${SOURCE}" "${remote[2]}@${remote[0]}:${remote[1]}"
fi

parsed="$(validate.remote "${SOURCE}")" || usage
mapfile -t remote <<< "${parsed}"
[[ -d "${DESTINATION}" ]] || { printf '[proxmox-transfer-rsync][error] Local destination directory does not exist: %s\n' "${DESTINATION}" >&2; exit 1; }
validate.local "${DESTINATION}" || { printf '[proxmox-transfer-rsync][error] Local destination must be within the selected transfer root.\n' >&2; exit 1; }
if [[ "${ACTION}" == verify-pull ]]; then
  exec rsync -rlptHAXS --safe-links --human-readable \
    --dry-run --checksum --itemize-changes --stats \
    -e "${SSH_WRAPPER}" -- "${remote[2]}@${remote[0]}:${remote[1]}" "${DESTINATION}"
fi
exec rsync -rlptHAXS --safe-links --partial --human-readable --info=progress2 \
  -e "${SSH_WRAPPER}" -- "${remote[2]}@${remote[0]}:${remote[1]}" "${DESTINATION}"
