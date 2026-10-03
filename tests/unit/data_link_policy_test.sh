#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "${FIXTURE_DIR}"' EXIT
FIXTURE="${FIXTURE_DIR}/interfaces"
TEMPLATE="${ROOT}/ansible/proxmox/templates/data-link.interfaces.j2"
RENDER_PLAYBOOK="${FIXTURE_DIR}/render.yml"
UNTAGGED_CANDIDATE="${FIXTURE_DIR}/interfaces.untagged"
VLAN_CANDIDATE="${FIXTURE_DIR}/interfaces.vlan-aware"

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

cat > "${RENDER_PLAYBOOK}" <<'EOF'
---
- name: Render DATA-Link candidate fixtures
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    proxmox_vlan_block_begin: "# BEGIN ANSIBLE MANAGED BLOCK: ansible-proxmox-data-bridge"
    proxmox_vlan_block_end: "# END ANSIBLE MANAGED BLOCK: ansible-proxmox-data-bridge"
  tasks:
    - name: Render untagged candidate with existing physical declaration
      ansible.builtin.template:
        src: "{{ lookup('env', 'DATA_LINK_TEMPLATE') }}"
        dest: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}/interfaces.untagged"
        mode: "0600"
      vars:
        proxmox_vlan_interfaces_without_owned_blocks: |
          auto lo
          iface lo inet loopback

          iface port7 inet manual
        proxmox_vlan_data_nic_iface_manual_exists: true
        proxmox_vlan_effective:
          data:
            nic: port7
            bridge: fabric7
            host_ip: null
            bridge_fd: 2
            bridge_vlan_aware: false
            bridge_vids: ""

    - name: Render VLAN-aware candidate without a physical declaration
      ansible.builtin.template:
        src: "{{ lookup('env', 'DATA_LINK_TEMPLATE') }}"
        dest: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}/interfaces.vlan-aware"
        mode: "0600"
      vars:
        proxmox_vlan_interfaces_without_owned_blocks: |
          auto lo
          iface lo inet loopback
        proxmox_vlan_data_nic_iface_manual_exists: false
        proxmox_vlan_effective:
          data:
            nic: port8
            bridge: fabric8
            host_ip: null
            bridge_fd: 2
            bridge_vlan_aware: true
            bridge_vids: "120 140-142"
EOF

DATA_LINK_TEMPLATE="${TEMPLATE}" \
DATA_LINK_FIXTURE_DIR="${FIXTURE_DIR}" \
  ansible-playbook -i localhost, -c local "${RENDER_PLAYBOOK}" >/dev/null

assert.canonical.candidate() {
  local candidate="$1" nic="$2" bridge_name="$3"
  [[ "$(awk -v nic="${nic}" '$1 == "iface" && $2 == nic {count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(awk -v bridge_name="${bridge_name}" '$1 == "iface" && $2 == bridge_name {count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(awk -v bridge_name="${bridge_name}" '$1 == "auto" && $2 == bridge_name {count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(awk -v nic="${nic}" '$1 == "bridge-ports" && $2 == nic {count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(grep -Fxc '# BEGIN ANSIBLE MANAGED BLOCK: ansible-proxmox-data-bridge' "${candidate}")" == 1 ]]
  [[ "$(grep -Fxc '# END ANSIBLE MANAGED BLOCK: ansible-proxmox-data-bridge' "${candidate}")" == 1 ]]
  ! grep -Fq '\n' "${candidate}"
}

assert.canonical.candidate "${UNTAGGED_CANDIDATE}" port7 fabric7
! grep -Fq 'bridge-vlan-aware' "${UNTAGGED_CANDIDATE}"
! grep -Eq '^[[:space:]]*(address|gateway)[[:space:]]' "${UNTAGGED_CANDIDATE}"

assert.canonical.candidate "${VLAN_CANDIDATE}" port8 fabric8
grep -Fqx '    bridge-vlan-aware yes' "${VLAN_CANDIDATE}"
grep -Fqx '    bridge-vids 120 140-142' "${VLAN_CANDIDATE}"

VLAN_PLAYBOOK="${ROOT}/ansible/proxmox/vlan.yml"
grep -Fq 'Parse complete DATA-Link candidate interface list' "${VLAN_PLAYBOOK}"
grep -Fq 'duplicate interface|invalid use of bridge attribute|interface not recognized' "${VLAN_PLAYBOOK}"
grep -Fq 'templates/data-link.interfaces.j2' "${VLAN_PLAYBOOK}"
grep -Fq 'literal_escape_count=0' "${VLAN_PLAYBOOK}"
! grep -Fq "~ '\\n'" "${VLAN_PLAYBOOK}"
! grep -Eq 'ip link set dev.*master' "${VLAN_PLAYBOOK}"

grep -Fq 'vlan.pending.yml' "${ROOT}/setup/vlan.sh"
grep -Fq 'vlan.applied.yml' "${ROOT}/setup/vlan.sh"
grep -Fq 'vlan.applied.yml' "${ROOT}/setup/network.sh"
grep -Fq 'no physical carrier was detected' "${ROOT}/setup/network-link.sh"

echo "[data_link_policy_test][ok] legacy recovery, rendered candidate structure, and transactional handoff contract"
