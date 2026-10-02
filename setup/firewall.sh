#!/usr/bin/env bash
## Restrict Proxmox host management ingress to its discovered local LAN.

set -euo pipefail
log() { printf '[setup.firewall] %s\n' "$*" >&2; }

APPLY_ACTIVE=0
BACKUP_PATH=""
HOST_FW_PATH=""
HOST_FW_EXISTED=0
CT_FW_PATH=""
CT_BACKUP_PATH=""
CT_FW_EXISTED=0
CLUSTER_ENABLE_BEFORE=0

rollback.apply() {
  ((APPLY_ACTIVE == 1)) || return 0
  set +e
  if ((HOST_FW_EXISTED == 1)); then
    cp -- "${BACKUP_PATH}" "${HOST_FW_PATH}"
  else
    rm -f -- "${HOST_FW_PATH}"
  fi
  if [[ -n "${CT_FW_PATH}" ]]; then
    if ((CT_FW_EXISTED == 1)); then
      cp -- "${CT_BACKUP_PATH}" "${CT_FW_PATH}"
    else
      rm -f -- "${CT_FW_PATH}"
    fi
  fi
  pvesh set /cluster/firewall/options --enable "${CLUSTER_ENABLE_BEFORE}" >/dev/null 2>&1
  APPLY_ACTIVE=0
  log "Apply failed; restored host/LXC firewall files and cluster firewall enable=${CLUSTER_ENABLE_BEFORE}."
}

die() {
  printf '[setup.firewall][error] %s\n' "$*" >&2
  rollback.apply
  exit 1
}

trap rollback.apply ERR

MODE="${1:-${PROXMOX_FIREWALL_MODE:-preflight}}"
MGMT_CIDR="${PROXMOX_FIREWALL_MANAGEMENT_CIDR:-}"
OOB_ACK="${PROXMOX_FIREWALL_CONFIRM_OOB:-}"
INTERACTIVE="${PROXMOX_FIREWALL_INTERACTIVE:-1}"
CTID="${PROXMOX_FIREWALL_CTID:-}"
DATA_SLOT="${PROXMOX_FIREWALL_LXC_DATA_SLOT:-}"
OPEN_TTY=0

is_true() { case "${1,,}" in 1|true|yes|y|on) return 0 ;; *) return 1 ;; esac; }
open_tty() { [[ -r /dev/tty ]] || return 1; exec 3<>/dev/tty; OPEN_TTY=1; }
prompt() {
  local label="$1" default="${2:-}" answer=""
  if [[ -n "${default}" ]]; then printf '%s [%s]: ' "${label}" "${default}" >&3; else printf '%s: ' "${label}" >&3; fi
  read -r -u 3 answer || true
  printf '%s\n' "${answer:-${default}}"
}

validate_cidr() {
  python3 - "${MGMT_CIDR}" "$1" <<'PY'
import ipaddress, sys
try:
    network = ipaddress.ip_network(sys.argv[1], strict=False)
    address = ipaddress.ip_address(sys.argv[2])
except ValueError:
    raise SystemExit(1)
if network.version != 4 or not network.is_private or address not in network or network.prefixlen < 8:
    raise SystemExit(1)
PY
}

main() {
  local node default_if mgmt_if mgmt_ip connected_cidr confirm existing_rules existing_cluster_rules findings comment
  local applied_rules node_options cluster_options existing_ct_rules ct_findings applied_ct_rules ct_options
  local line slot body net_ip net_bridge selected_body data_network
  local -a containers=() candidate_slots=()
  [[ "$(id -u)" -eq 0 ]] || die 'Run as root on the Proxmox host.'
  command -v pveversion >/dev/null 2>&1 || die 'pveversion was not found.'
  command -v pvesh >/dev/null 2>&1 || die 'pvesh was not found.'
  command -v pct >/dev/null 2>&1 || die 'pct was not found.'
  command -v python3 >/dev/null 2>&1 || die 'python3 was not found.'
  case "${MODE}" in preflight|apply) ;; *) die 'Mode must be preflight or apply.' ;; esac

  node="$(hostname -s)"
  default_if="$(ip route show default | awk 'NR==1 {print $5}')"
  mgmt_if="${default_if}"
  if [[ -L "/sys/class/net/${default_if}/master" ]]; then mgmt_if="$(basename "$(readlink -f "/sys/class/net/${default_if}/master")")"; fi
  mgmt_ip="$(ip -o -4 addr show dev "${mgmt_if}" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
  connected_cidr="$(ip -4 route show dev "${mgmt_if}" proto kernel scope link | awk 'NR==1 {print $1}')"
  MGMT_CIDR="${MGMT_CIDR:-${connected_cidr}}"
  mapfile -t containers < <(pct list 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+$/ {print $1}')
  if [[ -z "${CTID}" && ${#containers[@]} -eq 1 ]]; then CTID="${containers[0]}"; fi
  if is_true "${INTERACTIVE}" && open_tty; then
    MGMT_CIDR="$(prompt 'Management source CIDR allowed to SSH/HTTPS' "${MGMT_CIDR}")"
    CTID="$(prompt 'Samba ingest LXC CTID' "${CTID:-${containers[0]:-}}")"
  fi
  validate_cidr "${mgmt_ip}" || die "Management CIDR ${MGMT_CIDR:-empty} is not a private connected network containing ${mgmt_ip:-no-address}."
  [[ "${CTID}" =~ ^[0-9]+$ ]] && pct config "${CTID}" >/dev/null 2>&1 || die "Invalid or missing Samba LXC CTID: ${CTID:-empty}."

  while IFS= read -r line; do
    slot="${line%%:*}"
    body="${line#*: }"
    net_ip="$(printf '%s\n' "${body}" | tr ',' '\n' | sed -n 's/^ip=//p' | head -n1)"
    net_bridge="$(printf '%s\n' "${body}" | tr ',' '\n' | sed -n 's/^bridge=//p' | head -n1)"
    [[ "${slot}" =~ ^net[0-9]+$ && "${body}" == *'firewall=1'* ]] || continue
    [[ "${net_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || continue
    [[ ",${body}," != *,gw=* && ",${body}," != *,gw6=* ]] || continue
    [[ "${net_bridge}" != "${mgmt_if}" ]] || continue
    candidate_slots+=("${slot}")
  done < <(pct config "${CTID}" | grep -E '^net[0-9]+:' || true)
  if [[ -z "${DATA_SLOT}" && ${#candidate_slots[@]} -eq 1 ]]; then DATA_SLOT="${candidate_slots[0]}"; fi
  if is_true "${INTERACTIVE}" && ((OPEN_TTY == 1)); then
    DATA_SLOT="$(prompt 'Samba LXC data NIC slot' "${DATA_SLOT:-${candidate_slots[0]:-}}")"
  fi
  [[ "${DATA_SLOT}" =~ ^net[0-9]+$ ]] || die 'A discovered/operator-selected LXC data NIC slot is required.'
  selected_body="$(pct config "${CTID}" | sed -n "s/^${DATA_SLOT}: //p" | head -n1)"
  [[ -n "${selected_body}" && "${selected_body}" == *'firewall=1'* ]] || die "${DATA_SLOT} is missing or does not have firewall=1."
  [[ ",${selected_body}," != *,gw=* && ",${selected_body}," != *,gw6=* ]] || die "${DATA_SLOT} has a gateway and is not an isolated data role."
  net_ip="$(printf '%s\n' "${selected_body}" | tr ',' '\n' | sed -n 's/^ip=//p' | head -n1)"
  data_network="$(python3 - "${net_ip}" <<'PY'
import ipaddress, sys
try:
    interface = ipaddress.ip_interface(sys.argv[1])
except ValueError:
    raise SystemExit(1)
if interface.version != 4 or interface.network.is_global:
    raise SystemExit(1)
print(interface.network)
PY
)" || die "${DATA_SLOT} does not contain a non-global static IPv4/CIDR."

  existing_rules="$(pvesh get "/nodes/${node}/firewall/rules" --output-format json)"
  existing_cluster_rules="$(pvesh get /cluster/firewall/rules --output-format json)"
  existing_ct_rules="$(pvesh get "/nodes/${node}/lxc/${CTID}/firewall/rules" --output-format json)"
  findings="$(python3 -c '
import ipaddress, json, sys
allowed = ipaddress.ip_network(sys.argv[1], strict=False)
for scope, payload in (("node", sys.argv[2]), ("cluster", sys.argv[3])):
    for rule in json.loads(payload):
        if not rule.get("enable", 1) or rule.get("type") != "in" or str(rule.get("action", "")).upper() != "ACCEPT":
            continue
        source = rule.get("source")
        comment = rule.get("comment", "")
        try:
            source_net = ipaddress.ip_network(source, strict=False) if source else None
        except ValueError:
            source_net = None
        if source_net is None or not source_net.subnet_of(allowed):
            print("scope={} position={} source={} comment={}".format(scope, rule.get("pos", "?"), source or "ANY", comment))
' "${MGMT_CIDR}" "${existing_rules}" "${existing_cluster_rules}")"

  ct_findings="$(python3 -c '
import ipaddress, json, sys
allowed = ipaddress.ip_network(sys.argv[1], strict=False)
slot = sys.argv[2]
for rule in json.loads(sys.argv[3]):
    if not rule.get("enable", 1) or rule.get("type") != "in" or str(rule.get("action", "")).upper() != "ACCEPT":
        continue
    try:
        source = ipaddress.ip_network(rule.get("source", ""), strict=False)
    except ValueError:
        source = None
    exact = (source == allowed and rule.get("iface") == slot and rule.get("proto") == "tcp"
             and str(rule.get("dport")) == "445")
    if not exact:
        print("position={} iface={} source={} proto={} dport={} comment={}".format(
            rule.get("pos", "?"), rule.get("iface", "ANY"), rule.get("source", "ANY"),
            rule.get("proto", "ANY"), rule.get("dport", "ANY"), rule.get("comment", "")))
' "${data_network}" "${DATA_SLOT}" "${existing_ct_rules}")"

  printf '\nProxmox firewall plan:\n  node: %s\n  management interface: %s\n  host IP: %s\n  host allowed source: %s\n  host inbound ports: 22, 8006\n  LXC/data slot: %s/%s\n  LXC SMB source: %s -> tcp/445\n  input/output policy: DROP/ACCEPT\n' \
    "${node}" "${mgmt_if}" "${mgmt_ip}" "${MGMT_CIDR}" "${CTID}" "${DATA_SLOT}" "${data_network}" >&2
  [[ -z "${findings}" ]] || { printf '  conflicting broad ACCEPT rules:\n%s\n' "${findings}" >&2; [[ "${MODE}" != apply ]] || die 'Remove or narrow conflicting inbound ACCEPT rules before apply.'; }
  [[ -z "${ct_findings}" ]] || { printf '  conflicting LXC inbound ACCEPT rules:\n%s\n' "${ct_findings}" >&2; [[ "${MODE}" != apply ]] || die 'Remove non-SMB LXC inbound ACCEPT rules before apply.'; }
  [[ "${MODE}" == apply ]] || { log 'Preflight complete; no firewall change made.'; return; }
  [[ "${OOB_ACK}" == YES ]] || die 'Apply requires PROXMOX_FIREWALL_CONFIRM_OOB=YES.'
  if is_true "${INTERACTIVE}" && ((OPEN_TTY == 1)); then
    confirm="$(prompt 'Type yes to enable local-LAN-only host management ingress' 'no')"; [[ "${confirm}" == yes ]] || die 'Operator aborted.'
  fi

  HOST_FW_PATH="/etc/pve/nodes/${node}/host.fw"
  BACKUP_PATH="/var/backups/devs-guide-firewall/${node}.host.fw.$(date -u +%Y%m%dT%H%M%SZ).bak"
  mkdir -p "$(dirname "${BACKUP_PATH}")"
  if [[ -f "${HOST_FW_PATH}" ]]; then
    cp -- "${HOST_FW_PATH}" "${BACKUP_PATH}"
    HOST_FW_EXISTED=1
  else
    : > "${BACKUP_PATH}"
  fi
  CT_FW_PATH="/etc/pve/firewall/${CTID}.fw"
  CT_BACKUP_PATH="/var/backups/devs-guide-firewall/${CTID}.fw.$(date -u +%Y%m%dT%H%M%SZ).bak"
  if [[ -f "${CT_FW_PATH}" ]]; then
    cp -- "${CT_FW_PATH}" "${CT_BACKUP_PATH}"
    CT_FW_EXISTED=1
  else
    : > "${CT_BACKUP_PATH}"
  fi
  CLUSTER_ENABLE_BEFORE="$(pvesh get /cluster/firewall/options --output-format json | python3 -c 'import json,sys; print(int(bool(json.load(sys.stdin).get("enable", 0))))')"
  APPLY_ACTIVE=1

  for port in 22 8006; do
    comment="devs-guide local management tcp/${port}"
    if ! python3 -c '
import ipaddress, json, sys
comment, source, port = sys.argv[1:]
expected = ipaddress.ip_network(source, strict=False)
def matches(rule):
    try:
        actual = ipaddress.ip_network(rule.get("source", ""), strict=False)
    except ValueError:
        return False
    return (rule.get("comment") == comment and rule.get("type") == "in"
            and str(rule.get("action", "")).upper() == "ACCEPT"
            and rule.get("proto") == "tcp" and str(rule.get("dport")) == port
            and actual == expected and rule.get("enable", 1))
raise SystemExit(0 if any(matches(rule) for rule in json.load(sys.stdin)) else 1)
' "${comment}" "${MGMT_CIDR}" "${port}" <<< "${existing_rules}"
    then
      pvesh create "/nodes/${node}/firewall/rules" --type in --action ACCEPT --enable 1 \
        --source "${MGMT_CIDR}" --proto tcp --dport "${port}" --comment "${comment}"
    fi
  done
  comment="devs-guide Samba ingest tcp/445"
  if ! python3 -c '
import ipaddress, json, sys
source, slot, comment = ipaddress.ip_network(sys.argv[1], strict=False), sys.argv[2], sys.argv[3]
def matches(rule):
    try:
        actual = ipaddress.ip_network(rule.get("source", ""), strict=False)
    except ValueError:
        return False
    return (rule.get("comment") == comment and rule.get("type") == "in"
            and str(rule.get("action", "")).upper() == "ACCEPT" and rule.get("iface") == slot
            and rule.get("proto") == "tcp" and str(rule.get("dport")) == "445"
            and actual == source and rule.get("enable", 1))
raise SystemExit(0 if any(matches(rule) for rule in json.loads(sys.argv[4])) else 1)
' "${data_network}" "${DATA_SLOT}" "${comment}" "${existing_ct_rules}"
  then
    pvesh create "/nodes/${node}/lxc/${CTID}/firewall/rules" --type in --action ACCEPT --enable 1 \
      --iface "${DATA_SLOT}" --source "${data_network}" --proto tcp --dport 445 --comment "${comment}"
  fi
  pvesh set "/nodes/${node}/firewall/options" --enable 1 --policy_in DROP --policy_out ACCEPT
  pvesh set "/nodes/${node}/lxc/${CTID}/firewall/options" --enable 1 --policy_in DROP --policy_out ACCEPT
  pvesh set /cluster/firewall/options --enable 1
  applied_rules="$(pvesh get "/nodes/${node}/firewall/rules" --output-format json)"
  node_options="$(pvesh get "/nodes/${node}/firewall/options" --output-format json)"
  cluster_options="$(pvesh get /cluster/firewall/options --output-format json)"
  applied_ct_rules="$(pvesh get "/nodes/${node}/lxc/${CTID}/firewall/rules" --output-format json)"
  ct_options="$(pvesh get "/nodes/${node}/lxc/${CTID}/firewall/options" --output-format json)"
  python3 -c '
import ipaddress, json, sys
source = ipaddress.ip_network(sys.argv[1], strict=False)
rules = json.loads(sys.argv[2])
node = json.loads(sys.argv[3])
cluster = json.loads(sys.argv[4])
for port in ("22", "8006"):
    found = False
    for rule in rules:
        try:
            actual = ipaddress.ip_network(rule.get("source", ""), strict=False)
        except ValueError:
            continue
        if (rule.get("type") == "in" and str(rule.get("action", "")).upper() == "ACCEPT"
                and rule.get("proto") == "tcp" and str(rule.get("dport")) == port
                and actual == source and rule.get("enable", 1)):
            found = True
            break
    if not found:
        raise SystemExit("missing verified management rule for tcp/{}".format(port))
if not node.get("enable") or str(node.get("policy_in", "")).upper() != "DROP":
    raise SystemExit("node firewall policy verification failed")
if not cluster.get("enable"):
    raise SystemExit("cluster firewall enable verification failed")
' "${MGMT_CIDR}" "${applied_rules}" "${node_options}" "${cluster_options}"
  python3 -c '
import ipaddress, json, sys
source, slot = ipaddress.ip_network(sys.argv[1], strict=False), sys.argv[2]
rules, options = json.loads(sys.argv[3]), json.loads(sys.argv[4])
def matches(rule):
    try:
        actual = ipaddress.ip_network(rule.get("source", ""), strict=False)
    except ValueError:
        return False
    return (rule.get("type") == "in" and str(rule.get("action", "")).upper() == "ACCEPT"
            and rule.get("iface") == slot and rule.get("proto") == "tcp"
            and str(rule.get("dport")) == "445" and actual == source and rule.get("enable", 1))
if not any(matches(rule) for rule in rules):
    raise SystemExit("LXC SMB boundary rule verification failed")
if not options.get("enable") or str(options.get("policy_in", "")).upper() != "DROP":
    raise SystemExit("LXC firewall policy verification failed")
' "${data_network}" "${DATA_SLOT}" "${applied_ct_rules}" "${ct_options}"
  if command -v proxmox-firewall >/dev/null 2>&1; then
    proxmox-firewall compile >/dev/null
  elif command -v pve-firewall >/dev/null 2>&1; then
    pve-firewall status >/dev/null
  fi
  ss -lnt | grep -Eq ':22[[:space:]]|:8006[[:space:]]' || die 'Management listeners were not detected after policy apply.'
  APPLY_ACTIVE=0
  log "Host and LXC firewall boundaries enabled; recovery backups: ${BACKUP_PATH}, ${CT_BACKUP_PATH}"
}

main "$@"
