#!/usr/bin/env bash
## Configure an rsync-only SSH service on an operator-selected LXC DATA-Link.
##
## Exchange the public JSON bundles produced by `prepare`, then run `apply`
## with the other container's bundle on each side. Site addresses are always
## discovered or supplied by the operator; this runner contains no site map.

set -Eeuo pipefail

# Proxmox console/SSH environments can inherit stale per-login temp paths that
# do not exist inside the LXC. Package maintainer scripts must use the LXC's
# real sticky temporary directory.
unset TMP TEMP 2>/dev/null || true
export TMPDIR=/tmp

log()       { printf '[setup.lxc.transfer] %s\n' "$*" >&2; }
log.warn()  { printf '[setup.lxc.transfer][warn] %s\n' "$*" >&2; }
log.error() { printf '[setup.lxc.transfer][error] %s\n' "$*" >&2; }
die()       { log.error "$*"; exit 1; }

TMP_DIR="${PROXMOX_LXC_TRANSFER_TMP_DIR:-/tmp/pve-feature-lxc-transfer}"
PAGES_BASE_URL="${PROXMOX_PAGES_BASE_URL:-https://devs-guide.github.io/proxmox}"
PLAYBOOK_ROOT="${TMP_DIR}/ansible"
CLI_ROOT="${TMP_DIR}/cli"
GROUP_VARS_FILE="proxmox.yml"
GROUP_VARS_PATH="${PLAYBOOK_ROOT}/group_vars/${GROUP_VARS_FILE}"
FEATURE_PLAYBOOKS=(
  "proxmox/container/rsync.peer.yml"
)
FEATURE_SUPPORT_FILES=(
  "proxmox/tasks/lxc.transfer.ufw.yml"
)
FEATURE_CLI_FILES=(
  "ssh/peer.sh"
  "rsync/tree.sh"
  "network/speed.sh"
)
TRANSFER_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${FEATURE_PLAYBOOKS[0]}"
LOCAL_COMMON_HELPER="../../bootstrap/release.common.sh"
COMMON_HELPER_PATH="${TMP_DIR}/release.common.sh"
COMMON_HELPER_URL="${PAGES_BASE_URL}/release.common.sh"
ANSIBLE_VENV="/opt/ansible-venv"
ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"
ANSIBLE_CORE_VERSION="${PROXMOX_BOOTSTRAP_ANSIBLE_CORE_VERSION:-2.20.5}"
ANSIBLE_CORE_SPEC="ansible-core==${ANSIBLE_CORE_VERSION}"
PROXMOX_RUNTIME_CONTEXT="container"

MODE="${1:-${PROXMOX_LXC_TRANSFER_MODE:-preflight}}"
INTERACTIVE="${PROXMOX_LXC_TRANSFER_INTERACTIVE:-1}"
ASSUME_CONTAINER="${PROXMOX_LXC_TRANSFER_ASSUME_CONTAINER:-0}"
DATA_INTERFACE="${PROXMOX_LXC_TRANSFER_DATA_INTERFACE:-}"
LOCAL_CIDR="${PROXMOX_LXC_TRANSFER_LOCAL_CIDR:-}"
ALLOW_CIDR="${PROXMOX_LXC_TRANSFER_ALLOW_CIDR:-}"
TRANSFER_ROOT="${PROXMOX_LXC_TRANSFER_ROOT:-}"
ACCESS_GROUP="${PROXMOX_LXC_TRANSFER_ACCESS_GROUP:-}"
SERVICE_USER="${PROXMOX_LXC_TRANSFER_USER:-nas-transfer}"
PORT="${PROXMOX_LXC_TRANSFER_PORT:-22}"
IPERF_PORT=5201
PEER_BUNDLE="${PROXMOX_LXC_TRANSFER_PEER_BUNDLE:-}"
CONFIG_DIR="${PROXMOX_LXC_TRANSFER_CONFIG_DIR:-/etc/proxmox-transfer}"
FACTS_DIR="${PROXMOX_LXC_TRANSFER_FACTS_DIR:-/etc/ansible/proxmox/facts}"
SELECTION_PATH="${FACTS_DIR}/lxc.transfer.selection.yml"
RUNTIME_FACTS_PATH="${FACTS_DIR}/lxc.transfer.yml"
BUNDLE_OUT="${PROXMOX_LXC_TRANSFER_BUNDLE_OUT:-}"
SELF_URL="${PROXMOX_LXC_TRANSFER_SELF_URL:-${PAGES_BASE_URL}/setup/lxc/transfer.sh}"
SUDO_REEXEC="${PROXMOX_LXC_TRANSFER_SUDO_REEXEC:-0}"
EXTRA_VARS_PATH="${TMP_DIR}/lxc-transfer.extra-vars.json"
OPEN_TTY=0
LOCAL_ADDRESS=""

declare -a CANDIDATE_IFACES=()
declare -a CANDIDATE_CIDRS=()
declare -a CANDIDATE_NETWORKS=()

cleanup.transfer.temp() { rm -f -- "${EXTRA_VARS_PATH}" 2>/dev/null || true; }
trap cleanup.transfer.temp EXIT

is.true() { case "${1:-}" in 1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;; *) return 1 ;; esac; }

open.tty() {
  [[ -r /dev/tty ]] || return 1
  exec 3<>/dev/tty
  OPEN_TTY=1
}

prompt.tty() {
  local label="$1" default="${2:-}" answer=""
  if [[ -n "${default}" ]]; then
    printf '%s [%s]: ' "${label}" "${default}" >&3
  else
    printf '%s: ' "${label}" >&3
  fi
  read -r -u 3 answer || true
  printf '%s\n' "${answer:-${default}}"
}

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
  if command -v wget >/dev/null 2>&1; then
    wget -qO "${COMMON_HELPER_PATH}" "${COMMON_HELPER_URL}" || die "Unable to fetch ${COMMON_HELPER_URL}."
  else
    curl -fsSL "${COMMON_HELPER_URL}" -o "${COMMON_HELPER_PATH}" || die "Unable to fetch ${COMMON_HELPER_URL}."
  fi
  [[ -s "${COMMON_HELPER_PATH}" ]] || die 'The fetched release helper is empty.'
  # shellcheck source=/tmp/pve-feature-lxc-transfer/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

source.release.common

# release.common also supports newer Bash lowercase expansion. Re-declare the
# predicate so source-only policy tests and macOS operator workstations can
# inspect this runner with the system Bash 3.x.
is.true() { case "${1:-}" in 1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;; *) return 1 ;; esac; }

collect.sudo.env.args() {
  local -n out="$1"
  out=(
    "PROXMOX_LXC_TRANSFER_SUDO_REEXEC=1"
    "PROXMOX_LXC_TRANSFER_MODE=${MODE}"
    "PROXMOX_LXC_TRANSFER_INTERACTIVE=${INTERACTIVE}"
    "PROXMOX_LXC_TRANSFER_ASSUME_CONTAINER=${ASSUME_CONTAINER}"
    "PROXMOX_LXC_TRANSFER_DATA_INTERFACE=${DATA_INTERFACE}"
    "PROXMOX_LXC_TRANSFER_LOCAL_CIDR=${LOCAL_CIDR}"
    "PROXMOX_LXC_TRANSFER_ALLOW_CIDR=${ALLOW_CIDR}"
    "PROXMOX_LXC_TRANSFER_ROOT=${TRANSFER_ROOT}"
    "PROXMOX_LXC_TRANSFER_ACCESS_GROUP=${ACCESS_GROUP}"
    "PROXMOX_LXC_TRANSFER_USER=${SERVICE_USER}"
    "PROXMOX_LXC_TRANSFER_PORT=${PORT}"
    "PROXMOX_LXC_TRANSFER_PEER_BUNDLE=${PEER_BUNDLE}"
    "PROXMOX_LXC_TRANSFER_BUNDLE_OUT=${BUNDLE_OUT}"
    "PROXMOX_LXC_TRANSFER_CONFIG_DIR=${CONFIG_DIR}"
    "PROXMOX_LXC_TRANSFER_FACTS_DIR=${FACTS_DIR}"
    "PROXMOX_LXC_TRANSFER_TMP_DIR=${TMP_DIR}"
    "PROXMOX_LXC_TRANSFER_SELF_URL=${SELF_URL}"
    "PROXMOX_PAGES_BASE_URL=${PAGES_BASE_URL}"
    "PROXMOX_LXC_TRANSFER_CONFIRM_ROLLBACK=${PROXMOX_LXC_TRANSFER_CONFIRM_ROLLBACK:-}"
  )
}

require.mode() {
  case "${MODE}" in
    preflight|prepare|apply|verify|rotate|revoke|rollback) ;;
    *) die 'Mode must be preflight, prepare, apply, verify, rotate, revoke, or rollback.' ;;
  esac
}

require.container() {
  [[ -r /etc/os-release ]] || die 'Cannot identify this operating system.'
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == debian || "${ID_LIKE:-}" == *debian* ]] || die 'Run this feature inside a Debian-family LXC.'
  [[ ! -d /etc/pve ]] && ! command -v pveversion >/dev/null 2>&1 || die 'Run this feature inside the LXC, not on its Proxmox host.'
  if ! is.true "${ASSUME_CONTAINER}"; then
    command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --quiet --container \
      || die 'Container execution was not confirmed; set PROXMOX_LXC_TRANSFER_ASSUME_CONTAINER=1 only from an LXC console.'
  fi
}

normalize.network() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    value = ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
if (value.version != 4 or not value.is_private or value.is_loopback or value.is_link_local
        or value.is_multicast or value.prefixlen < 8 or value.prefixlen > 30):
    raise SystemExit(1)
print(value)
PY
}

normalize.interface() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    value = ipaddress.ip_interface(sys.argv[1])
except ValueError:
    raise SystemExit(1)
if (value.version != 4 or not value.network.is_private or value.ip.is_loopback or value.ip.is_link_local
        or value.ip.is_multicast or value.network.prefixlen < 8 or value.network.prefixlen > 30):
    raise SystemExit(1)
print(value)
print(value.ip)
print(value.network)
PY
}

discover.network.candidates() {
  local iface cidr canonical address network route default_route normalized_text
  local -a normalized=()
  CANDIDATE_IFACES=(); CANDIDATE_CIDRS=(); CANDIDATE_NETWORKS=()
  while read -r iface cidr; do
    [[ -n "${iface}" && "${iface}" != lo && -n "${cidr}" ]] || continue
    normalized_text="$(normalize.interface "${cidr}")" || continue
    mapfile -t normalized <<< "${normalized_text}"
    canonical="${normalized[0]}"; address="${normalized[1]}"; network="${normalized[2]}"
    route="$(ip -4 route show "${network}" dev "${iface}" 2>/dev/null || true)"
    default_route="$(ip -4 route show default dev "${iface}" 2>/dev/null || true)"
    [[ -n "${route}" && " ${route} " != *' via '* && -z "${default_route}" ]] || continue
    CANDIDATE_IFACES+=("${iface}")
    CANDIDATE_CIDRS+=("${canonical}")
    CANDIDATE_NETWORKS+=("${network}")
  done < <(ip -o -4 addr show scope global | awk '$0 !~ / dynamic / {print $2, $4}')
  ((${#CANDIDATE_IFACES[@]} > 0)) || die 'No directly connected, static IPv4 DATA-Link candidate was found.'
}

load.saved.selection() {
  local parsed
  local -a saved=()
  [[ -r "${SELECTION_PATH}" ]] || return 0
  parsed="$(python3 - "${SELECTION_PATH}" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())["proxmox_lxc_transfer_operator_selection"]
keys = ("data_interface", "local_cidr", "allow_cidr", "transfer_root", "access_group", "service_user", "port", "iperf_port")
for key in keys:
    print(data[key])
PY
  )" || die "Saved transfer selection is malformed: ${SELECTION_PATH}."
  mapfile -t saved <<< "${parsed}"
  ((${#saved[@]} == 8)) || die "Saved transfer selection is incomplete: ${SELECTION_PATH}."
  DATA_INTERFACE="${DATA_INTERFACE:-${saved[0]}}"
  LOCAL_CIDR="${LOCAL_CIDR:-${saved[1]}}"
  ALLOW_CIDR="${ALLOW_CIDR:-${saved[2]}}"
  TRANSFER_ROOT="${TRANSFER_ROOT:-${saved[3]}}"
  ACCESS_GROUP="${ACCESS_GROUP:-${saved[4]}}"
  [[ -n "${PROXMOX_LXC_TRANSFER_USER+x}" ]] || SERVICE_USER="${saved[5]}"
  [[ -n "${PROXMOX_LXC_TRANSFER_PORT+x}" ]] || PORT="${saved[6]}"
  [[ "${saved[7]}" == "${IPERF_PORT}" ]] || die "Saved iperf3 port must be ${IPERF_PORT}."
}

select.network() {
  local selected=-1 i choice normalized_network
  discover.network.candidates
  for i in "${!CANDIDATE_IFACES[@]}"; do
    if [[ -n "${DATA_INTERFACE}" && "${CANDIDATE_IFACES[$i]}" != "${DATA_INTERFACE}" ]]; then continue; fi
    if [[ -n "${LOCAL_CIDR}" && "${CANDIDATE_CIDRS[$i]}" != "${LOCAL_CIDR}" ]]; then continue; fi
    if ((selected >= 0)); then selected=-2; break; fi
    selected="${i}"
  done
  if ((selected < 0)) && is.true "${INTERACTIVE}" && ((OPEN_TTY == 1)); then
    printf '\nDirectly connected static IPv4 candidates:\n' >&3
    for i in "${!CANDIDATE_IFACES[@]}"; do
      printf '  %d) %s  %s  network=%s\n' "$((i + 1))" "${CANDIDATE_IFACES[$i]}" "${CANDIDATE_CIDRS[$i]}" "${CANDIDATE_NETWORKS[$i]}" >&3
    done
    choice="$(prompt.tty 'DATA-Link selection number' '1')"
    [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#CANDIDATE_IFACES[@]})) || die 'Invalid DATA-Link selection.'
    selected=$((choice - 1))
  fi
  ((selected >= 0)) || die 'DATA-Link selection is ambiguous; set PROXMOX_LXC_TRANSFER_DATA_INTERFACE and optionally PROXMOX_LXC_TRANSFER_LOCAL_CIDR.'
  DATA_INTERFACE="${CANDIDATE_IFACES[$selected]}"
  LOCAL_CIDR="${CANDIDATE_CIDRS[$selected]}"
  LOCAL_ADDRESS="${LOCAL_CIDR%/*}"
  ALLOW_CIDR="${ALLOW_CIDR:-${CANDIDATE_NETWORKS[$selected]}}"
  normalized_network="$(normalize.network "${ALLOW_CIDR}")" || die "Invalid private DATA-Link allow CIDR: ${ALLOW_CIDR}."
  ALLOW_CIDR="${normalized_network}"
  [[ "${ALLOW_CIDR}" == "${CANDIDATE_NETWORKS[$selected]}" ]] \
    || die "The allow CIDR must be the complete selected directly connected network (${CANDIDATE_NETWORKS[$selected]})."
}

show.storage.candidates() {
  local samba_mounts="${FACTS_DIR}/samba.mounts.tsv" discovered=""
  printf '\nDiscovered storage mountpoints (selection aid only):\n' >&2
  if [[ -r "${samba_mounts}" ]]; then
    discovered="$(awk -F '\t' 'NR == 1 {next} $2 ~ "^/(media|mnt|srv/storage|storage)(/|$)" {
      printf "  %s  source=%s  fstype=%s  readable=%s  writable=%s\n", $2, $3, $4, $6, $7
    }' "${samba_mounts}")"
    if [[ -n "${discovered}" ]]; then
      printf '%s\n' "${discovered}" >&2
      return
    fi
  fi
  findmnt -rn -o TARGET,SOURCE,FSTYPE 2>/dev/null \
    | awk '$1 ~ "^/(media|mnt|srv/storage|storage)(/|$)" {printf "  %s  source=%s  fstype=%s\n", $1, $2, $3}' >&2 \
    || true
}

select.storage() {
  show.storage.candidates
  if is.true "${INTERACTIVE}" && ((OPEN_TTY == 1)); then
    TRANSFER_ROOT="$(prompt.tty 'Existing transfer root (restricted rsync root)' "${TRANSFER_ROOT}")"
    ACCESS_GROUP="$(prompt.tty 'Existing group with read/write access to that root' "${ACCESS_GROUP:-samba}")"
  fi
  [[ "${TRANSFER_ROOT}" == /* && "${TRANSFER_ROOT}" != / && -d "${TRANSFER_ROOT}" && ! -L "${TRANSFER_ROOT}" ]] \
    || die 'PROXMOX_LXC_TRANSFER_ROOT must name an existing non-symlink directory below /.'
  [[ "${ACCESS_GROUP}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] && getent group "${ACCESS_GROUP}" >/dev/null \
    || die 'PROXMOX_LXC_TRANSFER_ACCESS_GROUP must name an existing storage access group.'
  [[ "${SERVICE_USER}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die 'Invalid transfer service user.'
  [[ "${PORT}" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || die 'Transfer port must be between 1 and 65535.'
}

default.bundle.path() {
  local short_host
  short_host="$(hostname -s | tr -cd 'A-Za-z0-9_.-')"
  BUNDLE_OUT="${BUNDLE_OUT:-/root/proxmox-transfer-${short_host:-lxc}.json}"
}

write.selection() {
  mkdir -p "${FACTS_DIR}"
  python3 - "${SELECTION_PATH}" "${DATA_INTERFACE}" "${LOCAL_CIDR}" "${ALLOW_CIDR}" "${TRANSFER_ROOT}" "${ACCESS_GROUP}" "${SERVICE_USER}" "${PORT}" "${IPERF_PORT}" <<'PY'
import json, pathlib, sys
path, iface, local, allowed, root, group, user, port, iperf_port = sys.argv[1:]
data = {"proxmox_lxc_transfer_operator_selection": {
    "confirmed": True, "source": "setup/lxc/transfer.sh", "data_interface": iface,
    "local_cidr": local, "allow_cidr": allowed, "transfer_root": root,
    "access_group": group, "service_user": user, "port": int(port), "iperf_port": int(iperf_port),
}}
target = pathlib.Path(path)
target.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
target.chmod(0o600)
PY
}

install.key.tools() {
  command -v ssh-keygen >/dev/null 2>&1 && return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends openssh-client
}

prepare.identities() {
  install.key.tools
  install -d -m 0755 "${CONFIG_DIR}"
  if [[ ! -f "${CONFIG_DIR}/ssh_host_ed25519_key" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C 'proxmox-lxc-transfer-host' -f "${CONFIG_DIR}/ssh_host_ed25519_key"
  fi
  if [[ ! -f "${CONFIG_DIR}/id_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C 'proxmox-lxc-transfer-client' -f "${CONFIG_DIR}/id_ed25519"
  fi
  chmod 0600 "${CONFIG_DIR}/ssh_host_ed25519_key" "${CONFIG_DIR}/id_ed25519"
  chmod 0644 "${CONFIG_DIR}/ssh_host_ed25519_key.pub" "${CONFIG_DIR}/id_ed25519.pub"
}

generate.bundle() {
  local host_fingerprint
  default.bundle.path
  host_fingerprint="$(ssh-keygen -lf "${CONFIG_DIR}/ssh_host_ed25519_key.pub" -E sha256 | awk '{print $2}')"
  python3 - "${BUNDLE_OUT}" "${LOCAL_ADDRESS}" "${PORT}" "${ALLOW_CIDR}" "${SERVICE_USER}" \
    "${CONFIG_DIR}/id_ed25519.pub" "${CONFIG_DIR}/ssh_host_ed25519_key.pub" "${host_fingerprint}" <<'PY'
import json, pathlib, sys
out, endpoint, port, network, user, client_path, host_path, fingerprint = sys.argv[1:]
def key(path):
    fields = pathlib.Path(path).read_text().strip().split()
    if len(fields) < 2 or fields[0] != "ssh-ed25519": raise SystemExit(f"invalid Ed25519 public key: {path}")
    return " ".join(fields[:2])
bundle = {
    "schema_version": 1,
    "kind": "server-peer",
    "endpoint": endpoint,
    "port": int(port),
    "allow_cidr": network,
    "service_user": user,
    "client_public_key": key(client_path),
    "server_host_public_key": key(host_path),
    "server_host_fingerprint": fingerprint,
}
target = pathlib.Path(out)
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(bundle, indent=2, sort_keys=True) + "\n")
target.chmod(0o644)
PY
  log "Public pairing bundle ready: ${BUNDLE_OUT}"
  log 'It contains public keys only; copy it to the other LXC and apply it there.'
}

parse.peer.bundle() {
  local parsed
  [[ -n "${PEER_BUNDLE}" && -r "${PEER_BUNDLE}" && ! -L "${PEER_BUNDLE}" ]] || die 'Set PROXMOX_LXC_TRANSFER_PEER_BUNDLE to a readable public pairing bundle.'
  parsed="$(python3 - "${PEER_BUNDLE}" "${ALLOW_CIDR}" "${PORT}" "${SERVICE_USER}" <<'PY'
import ipaddress, json, pathlib, re, sys
path, expected_network, expected_port, expected_user = sys.argv[1:]
data = json.loads(pathlib.Path(path).read_text())
required = {"schema_version", "kind", "allow_cidr", "service_user", "client_public_key"}
if not required.issubset(data) or data["schema_version"] != 1 or data["kind"] not in {"server-peer", "client"}:
    raise SystemExit("unsupported or incomplete transfer bundle")
network = ipaddress.ip_network(data["allow_cidr"], strict=False)
if (network.version != 4 or not network.is_private or network.is_loopback or network.is_link_local
        or network.is_multicast or not 8 <= network.prefixlen <= 30):
    raise SystemExit("bundle allow_cidr is not a private full DATA-Link network")
if expected_network and str(network) != expected_network: raise SystemExit("bundle allow_cidr does not match the selected DATA-Link")
endpoint = str(data.get("endpoint", ""))
port = int(data.get("port", 22))
if not 1 <= port <= 65535: raise SystemExit("bundle port is invalid")
service_user = str(data["service_user"])
if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,30}", service_user): raise SystemExit("bundle service user is invalid")
if service_user != expected_user: raise SystemExit("bundle service user does not match the local transfer profile")
if data["kind"] == "server-peer":
    if ipaddress.ip_address(endpoint) not in network: raise SystemExit("peer endpoint is outside the DATA-Link")
    if port != int(expected_port): raise SystemExit("peer port does not match the local transfer profile")
    if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/]+={0,3}", str(data.get("server_host_public_key", ""))):
        raise SystemExit("server peer bundle has no Ed25519 host key")
key = str(data["client_public_key"]).strip()
if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/]+={0,3}", key): raise SystemExit("invalid client public key")
values = [data["kind"], endpoint or "-", str(port), str(network), service_user, key,
          str(data.get("server_host_public_key", "")) or "-", str(data.get("server_host_fingerprint", "")) or "-"]
print("\n".join(values))
PY
  )" || die 'Peer bundle validation failed.'
  mapfile -t PEER_FIELDS <<< "${parsed}"
  ((${#PEER_FIELDS[@]} == 8)) || die 'Peer bundle parser returned an incomplete record.'
}

client.id() {
  python3 - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode()).hexdigest())
PY
}

write.extra.vars() {
  local peer_kind="$1" peer_endpoint="$2" peer_port="$3" peer_key="$4" peer_host_key="$5" client_id="$6" known_host_line=""
  if [[ "${peer_kind}" == server-peer ]]; then
    if [[ "${peer_port}" == 22 ]]; then
      known_host_line="${peer_endpoint} ${peer_host_key}"
    else
      known_host_line="[${peer_endpoint}]:${peer_port} ${peer_host_key}"
    fi
  fi
  mkdir -p "${TMP_DIR}"
  python3 - "${EXTRA_VARS_PATH}" "${DATA_INTERFACE}" "${LOCAL_ADDRESS}" "${LOCAL_CIDR}" "${ALLOW_CIDR}" \
    "${TRANSFER_ROOT}" "${ACCESS_GROUP}" "${SERVICE_USER}" "${PORT}" "${IPERF_PORT}" "${client_id}" "${peer_key}" "${peer_kind}" \
    "${PEER_BUNDLE}" "${known_host_line}" "${CONFIG_DIR}" "${FACTS_DIR}" "${SELECTION_PATH}" "${RUNTIME_FACTS_PATH}" <<'PY'
import json, pathlib, sys
(path, iface, address, local_cidr, allowed, root, group, user, port, iperf_port, client_id, client_key,
 kind, bundle, known_host, config, facts, selection, runtime) = sys.argv[1:]
data = {"proxmox_feature_defaults": {"lxc_transfer": {"enabled": True, "mode": "apply", "require_container": True,
        "require_operator_selection": True}}, "proxmox_lxc_transfer": {
    "enabled": True, "mode": "apply", "data_interface": iface, "local_address": address,
    "local_cidr": local_cidr, "allow_cidr": allowed, "transfer_root": root, "access_group": group,
    "service_user": user, "port": int(port), "iperf_port": int(iperf_port), "client_id": client_id, "client_public_key": client_key,
    "peer_kind": kind, "peer_bundle_path": bundle, "peer_known_host_line": known_host,
    "config_dir": config, "facts_dir": facts, "selection_path": selection, "runtime_facts_path": runtime}}
target = pathlib.Path(path); target.write_text(json.dumps(data, indent=2) + "\n"); target.chmod(0o600)
PY
}

use.local.feature.files() {
  local script_dir repo_root ref
  [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] || return 1
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/../.." && pwd)"
  [[ -r "${repo_root}/ansible/group_vars/${GROUP_VARS_FILE}" ]] || return 1
  for ref in "${FEATURE_PLAYBOOKS[@]}" "${FEATURE_SUPPORT_FILES[@]}"; do [[ -r "${repo_root}/ansible/${ref}" ]] || return 1; done
  for ref in "${FEATURE_CLI_FILES[@]}"; do [[ -r "${repo_root}/cli/${ref}" ]] || return 1; done
  PLAYBOOK_ROOT="${repo_root}/ansible"
  CLI_ROOT="${repo_root}/cli"
  GROUP_VARS_PATH="${PLAYBOOK_ROOT}/group_vars/${GROUP_VARS_FILE}"
  TRANSFER_PLAYBOOK_PATH="${PLAYBOOK_ROOT}/${FEATURE_PLAYBOOKS[0]}"
  log "Using local feature files from ${repo_root}."
}

fetch.feature.file() {
  local ref="$1" destination="${PLAYBOOK_ROOT}/$1"
  mkdir -p "$(dirname "${destination}")"
  if command -v wget >/dev/null 2>&1; then
    wget -qO "${destination}" "${PAGES_BASE_URL}/ansible/${ref}" || die "Unable to fetch ansible/${ref}."
  else
    curl -fsSL "${PAGES_BASE_URL}/ansible/${ref}" -o "${destination}" || die "Unable to fetch ansible/${ref}."
  fi
  [[ -s "${destination}" ]] || die "Fetched feature file is empty: ansible/${ref}."
}

prepare.feature.files() {
  local ref
  use.local.feature.files && return
  mkdir -p "${PLAYBOOK_ROOT}/group_vars"
  fetch.feature.file "group_vars/${GROUP_VARS_FILE}"
  for ref in "${FEATURE_PLAYBOOKS[@]}" "${FEATURE_SUPPORT_FILES[@]}"; do fetch.feature.file "${ref}"; done
  mkdir -p "${CLI_ROOT}"
  for ref in "${FEATURE_CLI_FILES[@]}"; do
    mkdir -p "$(dirname "${CLI_ROOT}/${ref}")"
    if command -v wget >/dev/null 2>&1; then
      wget -qO "${CLI_ROOT}/${ref}" "${PAGES_BASE_URL}/cli/${ref}" || die "Unable to fetch cli/${ref}."
    else
      curl -fsSL "${PAGES_BASE_URL}/cli/${ref}" -o "${CLI_ROOT}/${ref}" || die "Unable to fetch cli/${ref}."
    fi
  done
}

install.cli.helpers() {
  install -m 0755 "${CLI_ROOT}/ssh/peer.sh" /usr/local/sbin/proxmox-transfer-ssh
  install -m 0755 "${CLI_ROOT}/rsync/tree.sh" /usr/local/sbin/proxmox-transfer-rsync
  install -m 0755 "${CLI_ROOT}/network/speed.sh" /usr/local/sbin/proxmox-transfer-speed-test
}

remove.managed.ufw.rules() {
  local -a numbers=()
  command -v ufw >/dev/null 2>&1 || return 0
  mapfile -t numbers < <(ufw status numbered 2>/dev/null | awk 'index($0, "# proxmox-transfer-") {line=$0; sub(/^\[/,"",line); sub(/\].*$/,"",line); gsub(/[[:space:]]/,"",line); print line}' | sort -rn)
  local number
  for number in "${numbers[@]}"; do [[ "${number}" =~ ^[0-9]+$ ]] && ufw --force delete "${number}"; done
}

verify.feature() {
  local effective
  [[ -x /usr/local/libexec/proxmox-transfer-rrsync-guard ]] \
    || die 'The non-deleting forced-command guard is missing.'
  systemctl is-active --quiet proxmox-lxc-transfer-sshd.service || die 'Dedicated transfer sshd is not active.'
  systemctl is-enabled --quiet proxmox-lxc-transfer-sshd.service || die 'Dedicated transfer sshd is not enabled.'
  /usr/sbin/sshd -t -f "${CONFIG_DIR}/sshd_config"
  effective="$(/usr/sbin/sshd -T -f "${CONFIG_DIR}/sshd_config" -C "user=${SERVICE_USER},addr=${LOCAL_ADDRESS},host=localhost")"
  for required in \
    'passwordauthentication no' \
    'kbdinteractiveauthentication no' \
    'permitrootlogin no' \
    'permittty no' \
    'allowtcpforwarding no' \
    'allowagentforwarding no' \
    'permittunnel no'; do
    grep -Fq -- "${required}" <<< "${effective}" || die "Effective sshd policy is missing: ${required}."
  done
  grep -Fq 'forcecommand /usr/local/libexec/proxmox-transfer-rrsync-guard' <<< "${effective}" \
    || die 'Effective sshd policy does not force the non-deleting rrsync guard.'
  ss -H -lnt4 "sport = :${PORT}" | awk -v endpoint="${LOCAL_ADDRESS}:${PORT}" '$4 == endpoint {found=1} $4 ~ /^0\.0\.0\.0:/ {bad=1} END {exit(found && !bad ? 0 : 1)}' \
    || die 'Dedicated sshd is not bound exclusively to the selected DATA-Link address.'
  command -v iperf3 >/dev/null 2>&1 || die 'iperf3 is not installed.'
  [[ -x /usr/local/sbin/proxmox-transfer-speed-test ]] || die 'The iperf3 speed-test helper is missing.'
  [[ -x /usr/local/sbin/proxmox-transfer-rsync ]] || die 'The managed rsync helper is missing.'
  command -v screen >/dev/null 2>&1 || die 'GNU Screen is missing for managed transfer jobs.'
  ! ss -H -lnt4 "sport = :${IPERF_PORT}" | grep -q . || die 'TCP/5201 has a listener outside an operator-started speed test.'
  ufw status | grep -Fq 'proxmox-transfer-ssh-in' || die 'Managed transfer SSH ingress UFW rule is missing.'
  ufw status | grep -Fq 'proxmox-transfer-ssh-out' || die 'Managed transfer SSH egress UFW rule is missing.'
  ufw status | grep -Fq 'proxmox-transfer-iperf-in' || die 'Managed iperf3 ingress UFW rule is missing.'
  ufw status | grep -Fq 'proxmox-transfer-iperf-out' || die 'Managed iperf3 egress UFW rule is missing.'
  "${CONFIG_DIR}/authorized-keys-command" "${SERVICE_USER}" | grep -Fq "from=\"${ALLOW_CIDR}\"" \
    || die 'No authorized transfer client is constrained to the selected DATA-Link CIDR.'
  log "Verified rsync-only SSH on ${LOCAL_ADDRESS}:${PORT} and on-demand iperf3 tcp/${IPERF_PORT} across ${ALLOW_CIDR}."
}

rotate.identity() {
  local stamp
  [[ -f "${CONFIG_DIR}/id_ed25519" ]] || die 'No prepared client identity exists to rotate.'
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -m 0700 "${CONFIG_DIR}/retired"
  mv "${CONFIG_DIR}/id_ed25519" "${CONFIG_DIR}/retired/id_ed25519.${stamp}"
  mv "${CONFIG_DIR}/id_ed25519.pub" "${CONFIG_DIR}/retired/id_ed25519.${stamp}.pub"
  ssh-keygen -q -t ed25519 -N '' -C 'proxmox-lxc-transfer-client' -f "${CONFIG_DIR}/id_ed25519"
  chmod 0600 "${CONFIG_DIR}/id_ed25519"
  chmod 0644 "${CONFIG_DIR}/id_ed25519.pub"
  generate.bundle
  log 'Outgoing client identity rotated. Apply the new bundle on every destination, then revoke the old bundle.'
}

revoke.client() {
  local id
  parse.peer.bundle
  id="$(client.id "${PEER_FIELDS[5]}")"
  if [[ -f "${CONFIG_DIR}/clients.d/${id}.pub" ]]; then
    rm -f -- "${CONFIG_DIR}/clients.d/${id}.pub"
    log "Revoked client ${id}."
  else
    log.warn "Client ${id} was not authorized on this container."
  fi
}

rollback.feature() {
  local confirmation="${PROXMOX_LXC_TRANSFER_CONFIRM_ROLLBACK:-}"
  if is.true "${INTERACTIVE}" && ((OPEN_TTY == 1)); then confirmation="$(prompt.tty 'Type yes to remove the transfer service and managed rules' 'no')"; fi
  [[ "${confirmation}" == yes || "${confirmation}" == YES ]] || die 'Rollback requires PROXMOX_LXC_TRANSFER_CONFIRM_ROLLBACK=yes.'
  systemctl disable --now proxmox-lxc-transfer-sshd.service 2>/dev/null || true
  remove.managed.ufw.rules
  rm -f -- /etc/systemd/system/proxmox-lxc-transfer-sshd.service \
    /usr/local/libexec/proxmox-transfer-authorized-keys /usr/local/libexec/proxmox-transfer-data-ready \
    /usr/local/libexec/proxmox-transfer-rrsync /usr/local/libexec/proxmox-transfer-rrsync-guard \
    /usr/local/sbin/proxmox-transfer-ssh /usr/local/sbin/proxmox-transfer-rsync \
    /usr/local/sbin/proxmox-transfer-speed-test \
    "${CONFIG_DIR}/authorized-keys-command" "${CONFIG_DIR}/sshd_config" "${CONFIG_DIR}/known_hosts" \
    "${RUNTIME_FACTS_PATH}" "${SELECTION_PATH}"
  if [[ -d "${CONFIG_DIR}/clients.d" ]]; then find "${CONFIG_DIR}/clients.d" -maxdepth 1 -type f -name '*.pub' -delete; fi
  if [[ -d "${CONFIG_DIR}/peers.d" ]]; then find "${CONFIG_DIR}/peers.d" -maxdepth 1 -type f -name '*.json' -delete; fi
  systemctl daemon-reload
  log "Transfer runtime removed. Recovery identities remain under ${CONFIG_DIR}."
}

show.plan() {
  printf '\nLXC transfer plan:\n  mode: %s\n  data interface: %s\n  local SSH endpoint: %s:%s\n  one-shot iperf3 endpoint: %s:%s\n  complete DATA-Link CIDR: %s\n  transfer root: %s\n  access group: %s\n  service user: %s\n  SSH policy: Ed25519 keys, non-deleting forced rrsync, no shell/PTY/forwarding\n' \
    "${MODE}" "${DATA_INTERFACE}" "${LOCAL_ADDRESS}" "${PORT}" "${LOCAL_ADDRESS}" "${IPERF_PORT}" "${ALLOW_CIDR}" "${TRANSFER_ROOT}" "${ACCESS_GROUP}" "${SERVICE_USER}" >&2
}

main() {
  local id
  ensure.root.or.sudo.reexec "${SUDO_REEXEC}" "${SELF_URL}" "$@"
  require.root
  require.mode
  require.container
  command -v python3 >/dev/null 2>&1 || die 'python3 is required.'
  is.true "${INTERACTIVE}" && open.tty || true

  if [[ "${MODE}" == rollback ]]; then rollback.feature; return; fi
  if [[ "${MODE}" == revoke ]]; then load.saved.selection; revoke.client; return; fi

  load.saved.selection
  select.network
  select.storage
  default.bundle.path
  show.plan
  [[ "${MODE}" != preflight ]] || { log 'Preflight complete; no state changed.'; return; }

  write.selection
  if [[ "${MODE}" == prepare ]]; then prepare.identities; generate.bundle; return; fi
  if [[ "${MODE}" == rotate ]]; then rotate.identity; return; fi
  if [[ "${MODE}" == verify ]]; then verify.feature; return; fi

  [[ "${MODE}" == apply ]] || die "Unhandled mode: ${MODE}."
  [[ -f "${CONFIG_DIR}/id_ed25519" && -f "${CONFIG_DIR}/ssh_host_ed25519_key" ]] \
    || die 'Run prepare before apply.'
  parse.peer.bundle
  id="$(client.id "${PEER_FIELDS[5]}")"
  write.extra.vars "${PEER_FIELDS[0]}" "${PEER_FIELDS[1]}" "${PEER_FIELDS[2]}" "${PEER_FIELDS[5]}" "${PEER_FIELDS[6]}" "${id}"
  ensure.container.ansible
  prepare.feature.files
  ansible.runtime.run -i localhost, -c local -e "@${GROUP_VARS_PATH}" -e "@${EXTRA_VARS_PATH}" "${TRANSFER_PLAYBOOK_PATH}"
  install.cli.helpers
  rm -f -- "${EXTRA_VARS_PATH}"
  generate.bundle
  verify.feature
}

if ! is.true "${PROXMOX_LXC_TRANSFER_SOURCE_ONLY:-0}"; then
  main "$@"
fi
