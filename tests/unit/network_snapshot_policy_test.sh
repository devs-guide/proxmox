#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROXMOX_NETWORK_SOURCE_ONLY=1
# shellcheck source=setup/network.sh
source "${ROOT}/setup/network.sh"

fail() {
  printf '[network_snapshot_policy_test][error] %s\n' "$*" >&2
  exit 1
}

assert.equal() {
  local expected="$1" actual="$2" label="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${label}: expected=${expected} actual=${actual}"
}

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT
RUN_DIR="${TEST_ROOT}/synthetic-host.fixture"
mkdir -p "${RUN_DIR}/raw/lxc/4242" "${RUN_DIR}/raw/vm"
set.run.paths.from.dir

printf 'header\n' > "${TEST_ROOT}/rows.tsv"
assert.equal 0 "$(tsv.data.row.count "${TEST_ROOT}/rows.tsv")" 'header-only TSV row count'
printf 'one\ntwo\n' >> "${TEST_ROOT}/rows.tsv"
assert.equal 2 "$(tsv.data.row.count "${TEST_ROOT}/rows.tsv")" 'two-row TSV count'

printf 'iface\tkind\tmac\tmtu\toperstate\tcarrier\tspeed\tduplex\tdriver\tpci_slot\tmaster\tipv4\tipv6\n' > "${NICS_TSV_PATH}"
printf 'mgmtphy\tphysical\t02:00:00:00:00:01\t1500\tup\t1\t1000\tfull\tigc\t0000:01:00.0\tbr-mgmt\t\t\n' >> "${NICS_TSV_PATH}"
printf 'dataphy\tphysical\t02:00:00:00:00:02\t1500\tdown\t0\t10000\tfull\tixgbe\t0000:02:00.0\tbr-data\t\t\n' >> "${NICS_TSV_PATH}"
printf 'br-mgmt\tbridge\t02:00:00:00:00:01\t1500\tup\t1\t\t\t\t\t\t192.0.2.10/24\t\n' >> "${NICS_TSV_PATH}"
printf 'br-data\tbridge\t02:00:00:00:00:02\t1500\tdown\t0\t\t\t\t\t\t\t\n' >> "${NICS_TSV_PATH}"

printf 'bridge\tvlan_filtering\tmembers\tipv4\tipv6\n' > "${BRIDGES_TSV_PATH}"
printf 'br-mgmt\t0\tmgmtphy\t192.0.2.10/24\t\n' >> "${BRIDGES_TSV_PATH}"
printf 'br-data\t0\tdataphy\t\t\n' >> "${BRIDGES_TSV_PATH}"
printf 'port\tvlan_detail\n' > "${VLANS_TSV_PATH}"
printf 'guest_type\tguest_id\tguest_name\tstatus\tnet_slot\tguest_if\tbridge\tvlan_tag\ttrunks\tfirewall\tmtu\tip_hint\tgw_hint\traw\n' > "${LXC_TSV_PATH}"
printf 'lxc\t4242\tfixture-guest\trunning\tnet7\tuplink0\tbr-mgmt\t-\t-\t1\t1500\tdhcp\t192.0.2.1\tname=uplink0,bridge=br-mgmt,firewall=1,ip=dhcp\n' >> "${LXC_TSV_PATH}"
printf 'guest_type\tguest_id\tguest_name\tstatus\tnet_slot\tmodel\tmac\tbridge\tvlan_tag\ttrunks\tfirewall\tmtu\traw\n' > "${VM_TSV_PATH}"
printf 'guest_type\tguest_id\tguest_name\tstatus\truntime_source\tipv4_interfaces\tdefault_route\tlisten_summary\tsysctl_summary\n' > "${GUEST_RUNTIME_TSV_PATH}"
printf 'lxc\t4242\tfixture-guest\trunning\tpct_exec\tuplink0=192.0.2.40/24\tdefault via 192.0.2.1 dev uplink0\t-\t-\n' >> "${GUEST_RUNTIME_TSV_PATH}"
printf 'guest_type\tguest_id\tguest_name\tstatus\tservice_present\tinterfaces\tbind_interfaces_only\thosts_allow\tsmb_ports\tufw_summary\n' > "${SAMBA_TSV_PATH}"
printf 'lxc\t4242\tfixture-guest\trunning\tno\t-\t-\t-\t-\t-\n' >> "${SAMBA_TSV_PATH}"
printf 'severity\tscope\tguest_id\tguest_name\tcode\tdetail\n' > "${RISKS_TSV_PATH}"

validate.collection.artifacts || fail 'synthetic TSV schemas were rejected'

HOSTNAME_SHORT='synthetic-host'
COLLECTED_AT='2030-01-02 03:04:05 UTC'
EXPECTED_ADMIN_BRIDGE='br-mgmt'
DISCOVERED_ADMIN_BRIDGE='br-mgmt'
DISCOVERED_ADMIN_NIC='mgmtphy'
DISCOVERED_ADMIN_NICS='mgmtphy'
DISCOVERED_ADMIN_IP_CIDR='192.0.2.10/24'
EXPECTED_MANAGEMENT_CIDR='192.0.2.0/24'
EXPECTED_DATA_BRIDGE='br-data'
CT_IDS=(4242)

DISCOVERED_DATA_BRIDGE=''
DISCOVERED_DATA_NICS=''
printf 'error\thost\t-\tsynthetic-host\tmissing_data_bridge\tExpected data bridge br-data was not found.\n' >> "${RISKS_TSV_PATH}"
evaluate.snapshot.readiness
assert.equal false "${SNAPSHOT_READY_FOR_UPDATE}" 'missing bridge readiness'
[[ ",${SNAPSHOT_BLOCKING_CODES}," == *',missing_data_bridge,'* ]] || fail 'missing bridge blocker was not recorded'

printf 'severity\tscope\tguest_id\tguest_name\tcode\tdetail\n' > "${RISKS_TSV_PATH}"
DISCOVERED_DATA_BRIDGE='br-data'
DISCOVERED_DATA_NICS='dataphy'
evaluate.snapshot.readiness
assert.equal true "${SNAPSHOT_COLLECTION_COMPLETE}" 'valid fixture collection state'
assert.equal true "${SNAPSHOT_READY_FOR_UPDATE}" 'valid fixture readiness'
assert.equal '' "${SNAPSHOT_BLOCKING_CODES}" 'valid fixture blocking codes'

write.snapshot.status
mark.snapshot.ready
grep -Fxq '  collection_complete: true' "${SNAPSHOT_STATUS_PATH}" || fail 'complete snapshot status is missing'
grep -Fxq '  ready_for_update: true' "${SNAPSHOT_STATUS_PATH}" || fail 'ready snapshot status is missing'
grep -Fxq 'selected_data_bridge=br-data' "${SNAPSHOT_READY_PATH}" || fail 'ready marker bridge is missing'

assert.equal '198.51.100.0/24' "$(derive.ipv4.network.cidr '198.51.100.40/24')" 'data network derivation'
ipv4.cidrs.overlap '192.0.2.0/24' '192.0.2.128/25' || fail 'overlapping CIDRs were not detected'
if ipv4.cidrs.overlap '192.0.2.0/24' '198.51.100.0/24'; then
  fail 'separate management and data CIDRs were treated as overlapping'
fi

printf '[network_snapshot_policy_test][ok] fail-closed snapshot and CIDR policy\n'
