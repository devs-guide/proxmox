#!/usr/bin/env bash
## Run an on-demand iperf3 test on the operator-selected LXC DATA-Link.

set -euo pipefail

ACTION="${1:-}"
PEER="${2:-}"
SELECTION_PATH="${PROXMOX_LXC_TRANSFER_SELECTION_PATH:-/etc/ansible/proxmox/facts/lxc.transfer.selection.yml}"
IPERF_PORT=5201
IPERF_SECONDS="${PROXMOX_LXC_TRANSFER_IPERF_SECONDS:-15}"
IPERF_STREAMS="${PROXMOX_LXC_TRANSFER_IPERF_STREAMS:-4}"

die() { printf '[proxmox-transfer-speed-test][error] %s\n' "$*" >&2; exit 1; }

usage() {
  printf 'usage: %s server\n       %s client PEER_IPV4\n' "$0" "$0" >&2
  exit 2
}

[[ "${ACTION}" == server || "${ACTION}" == client ]] || usage
if [[ "${ACTION}" == server ]]; then
  [[ $# -eq 1 ]] || usage
else
  [[ $# -eq 2 && -n "${PEER}" ]] || usage
fi

command -v iperf3 >/dev/null 2>&1 || die 'iperf3 is required.'
command -v python3 >/dev/null 2>&1 || die 'python3 is required.'
[[ -r "${SELECTION_PATH}" ]] || die "Missing transfer selection: ${SELECTION_PATH}"
[[ "${IPERF_SECONDS}" =~ ^[0-9]+$ ]] && ((IPERF_SECONDS >= 1 && IPERF_SECONDS <= 300)) \
  || die 'PROXMOX_LXC_TRANSFER_IPERF_SECONDS must be between 1 and 300.'
[[ "${IPERF_STREAMS}" =~ ^[0-9]+$ ]] && ((IPERF_STREAMS >= 1 && IPERF_STREAMS <= 16)) \
  || die 'PROXMOX_LXC_TRANSFER_IPERF_STREAMS must be between 1 and 16.'

selection="$(
  python3 - "${SELECTION_PATH}" "${PEER}" "${ACTION}" 2>/dev/null <<'PY'
import ipaddress, json, pathlib, sys

path, peer_text, action = sys.argv[1:]
data = json.loads(pathlib.Path(path).read_text())["proxmox_lxc_transfer_operator_selection"]
interface = ipaddress.ip_interface(data["local_cidr"])
allowed = ipaddress.ip_network(data["allow_cidr"], strict=False)
if interface.network != allowed or int(data["iperf_port"]) != 5201:
    raise SystemExit("saved local address and allowed CIDR do not match")
print(data["data_interface"])
print(interface.ip)
print(allowed)
if action == "client":
    peer = ipaddress.ip_address(peer_text)
    if peer.version != 4 or peer not in allowed or peer == interface.ip:
        raise SystemExit("peer must be another IPv4 address on the selected DATA-Link")
    print(peer)
PY
)" || die 'Saved transfer selection or peer address is invalid.'
mapfile -t selected <<< "${selection}"
[[ ${#selected[@]} -ge 3 ]] || die 'Saved transfer selection is incomplete.'
DATA_INTERFACE="${selected[0]}"
LOCAL_ADDRESS="${selected[1]}"

ip -o -4 addr show dev "${DATA_INTERFACE}" scope global \
  | awk -v expected="${LOCAL_ADDRESS}" '{split($4, value, "/"); if (value[1] == expected) found=1} END {exit(found ? 0 : 1)}' \
  || die 'The selected DATA-Link address is not active.'

if [[ "${ACTION}" == server ]]; then
  printf '[proxmox-transfer-speed-test] One-shot server: %s:%s\n' "${LOCAL_ADDRESS}" "${IPERF_PORT}" >&2
  exec iperf3 --server --one-off --bind "${LOCAL_ADDRESS}" --port "${IPERF_PORT}"
fi

PEER="${selected[3]}"
printf '[proxmox-transfer-speed-test] Client: %s -> %s:%s (%ss, %s streams)\n' \
  "${LOCAL_ADDRESS}" "${PEER}" "${IPERF_PORT}" "${IPERF_SECONDS}" "${IPERF_STREAMS}" >&2
exec iperf3 --client "${PEER}" --port "${IPERF_PORT}" \
  --time "${IPERF_SECONDS}" --parallel "${IPERF_STREAMS}"
