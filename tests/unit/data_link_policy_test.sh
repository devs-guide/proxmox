#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "${FIXTURE_DIR}"' EXIT
FIXTURE="${FIXTURE_DIR}/interfaces"

cat > "${FIXTURE}" <<'EOF'
auto lo
iface lo inet loopback

iface data7 inet manual

auto adminbr0
iface adminbr0 inet static
    address 192.0.2.10/24
    gateway 192.0.2.1
    bridge-ports admin7

# BEGIN ANSIBLE MANAGED BLOCK: ansible-proxmox-vlan-vmbr1
iface data7 inet manual

auto lanbr7
iface lanbr7 inet manual    bridge-ports data7
    bridge-stp off
    bridge-fd 2
# END ANSIBLE MANAGED BLOCK: ansible-proxmox-vlan-vmbr1
EOF

export PROXMOX_VLAN_SOURCE_ONLY=1
export PROXMOX_VLAN_INTERFACES_PATH="${FIXTURE}"
# shellcheck source=setup/vlan.sh
source "${ROOT}/setup/vlan.sh"

NIC_IFACE=(data7)
NIC_DRIVER=(test_driver)
NIC_PCI=(0000:03:00.0)
NIC_MAC=(02:00:00:00:00:07)
NIC_PERMANENT_MAC=(02:00:00:00:00:07)

load.managed.block.selection
[[ "${PERSISTED_DATA_NIC}" == data7 ]]
[[ "${PERSISTED_DATA_BRIDGE}" == lanbr7 ]]
[[ "${PERSISTED_DATA_LINK_MODE}" == untagged ]]
[[ "${PERSISTED_FROM_MANAGED_BLOCK}" == 1 ]]

VLAN_PLAYBOOK="${ROOT}/ansible/proxmox/vlan.yml"
grep -Fq 'Parse complete DATA-Link candidate interface list' "${VLAN_PLAYBOOK}"
grep -Fq 'duplicate interface|invalid use of bridge attribute|interface not recognized' "${VLAN_PLAYBOOK}"
grep -Fq 'iface ' "${VLAN_PLAYBOOK}"
! grep -Fq 'inet {% if' "${VLAN_PLAYBOOK}"
! grep -Eq 'ip link set dev.*master' "${VLAN_PLAYBOOK}"

grep -Fq 'vlan.pending.yml' "${ROOT}/setup/vlan.sh"
grep -Fq 'vlan.applied.yml' "${ROOT}/setup/vlan.sh"
grep -Fq 'vlan.applied.yml' "${ROOT}/setup/network.sh"
grep -Fq 'no physical carrier was detected' "${ROOT}/setup/network-link.sh"

echo "[data_link_policy_test][ok] legacy recovery, candidate validation, and transactional handoff contract"
