#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="${ROOT}/ansible/proxmox/helper/network.lxc_nic.py"
EXPECTED='name=data0,bridge=br-data,firewall=1,ip=198.51.100.40/24'

fail() {
  printf '[network_lxc_nic_policy_test][error] %s\n' "$*" >&2
  exit 1
}

expect.ok() {
  local actual="$1" output
  output="$(python3 "${HELPER}" compare --expected "${EXPECTED}" --actual "${actual}")" \
    || fail "expected semantic match: ${actual}"
  [[ "${output}" == ok$'\t'* ]] || fail "matching definition did not report ok: ${output}"
}

expect.status() {
  local expected_status="$1" actual="$2" output rc=0
  output="$(python3 "${HELPER}" compare --expected "${EXPECTED}" --actual "${actual}" 2>&1)" || rc=$?
  [[ "${rc}" -ne 0 ]] || fail "expected ${expected_status} rejection: ${actual}"
  [[ "${output}" == "${expected_status}"$'\t'* ]] \
    || fail "expected status=${expected_status}, observed=${output}"
}

expect.ok "${EXPECTED}"
expect.ok 'type=veth,hwaddr=02:00:00:00:00:40,ip=198.51.100.40/24,firewall=1,bridge=br-data,name=data0'

expect.status value_mismatch 'name=data1,bridge=br-data,firewall=1,ip=198.51.100.40/24'
expect.status value_mismatch 'name=data0,bridge=br-other,firewall=1,ip=198.51.100.40/24'
expect.status value_mismatch 'name=data0,bridge=br-data,firewall=0,ip=198.51.100.40/24'
expect.status value_mismatch 'name=data0,bridge=br-data,firewall=1,ip=198.51.100.41/24'
expect.status unsafe_data_route 'name=data0,bridge=br-data,firewall=1,ip=198.51.100.40/24,gw=198.51.100.1'
expect.status unsafe_data_route 'name=data0,bridge=br-data,firewall=1,ip=dhcp'
expect.status vlan_not_allowed 'name=data0,bridge=br-data,firewall=1,ip=198.51.100.40/24,tag=40'
expect.status vlan_not_allowed 'name=data0,bridge=br-data,firewall=1,ip=198.51.100.40/24,trunks=40;41'
expect.status link_down 'name=data0,bridge=br-data,firewall=1,ip=198.51.100.40/24,link_down=1'
expect.status unexpected_field 'name=data0,bridge=br-data,firewall=1,ip=198.51.100.40/24,rate=100'
expect.status unexpected_type 'name=data0,bridge=br-data,firewall=1,ip=198.51.100.40/24,type=tap'
expect.status invalid_hwaddr 'name=data0,bridge=br-data,firewall=1,ip=198.51.100.40/24,hwaddr=invalid'
expect.status malformed_actual 'name=data0,bridge=br-data,bridge=br-data,firewall=1,ip=198.51.100.40/24'
expect.status malformed_actual 'name=data0,bridge=br-data,firewall=1,ip=198.51.100.40/24,broken'
expect.status missing_slot ''

printf '%s\n' \
  'net0: type=veth,bridge=br-mgmt,name=mgmt0,firewall=1,ip=dhcp' \
  'net1: type=veth,bridge=br-data,name=data0,firewall=1,ip=198.51.100.40/24' \
  | python3 "${HELPER}" config-has-name --name mgmt0 >/dev/null \
  || fail 'token-aware management interface lookup failed'

if printf '%s\n' 'net0: type=veth,bridge=br-mgmt,name=mgmt0,firewall=1,ip=dhcp' \
  | python3 "${HELPER}" config-has-name --name data0 >/dev/null 2>&1; then
  fail 'missing interface name was accepted'
fi

printf '[network_lxc_nic_policy_test][ok] production semantic parser policy\n'
