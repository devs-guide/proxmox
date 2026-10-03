#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "${FIXTURE_DIR}"' EXIT
FIXTURE="${FIXTURE_DIR}/interfaces"
TEMPLATE="${ROOT}/ansible/proxmox/templates/data-link.interfaces.j2"
RENDER_PLAYBOOK="${FIXTURE_DIR}/render.yml"
HOST_CANDIDATE="${FIXTURE_DIR}/interfaces.host-shaped"
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
    proxmox_vlan_owned_block_pattern: '(?ms)^\# BEGIN ANSIBLE MANAGED BLOCK: (?:ansible-proxmox-data-bridge|ansible-proxmox-vlan-vmbr1|devsguide-proxmox-vlan-vmbr1)\n.*?^\# END ANSIBLE MANAGED BLOCK: (?:ansible-proxmox-data-bridge|ansible-proxmox-vlan-vmbr1|devsguide-proxmox-vlan-vmbr1)\n?'
    data_link_method_cases:
      - name: absent
        nic: port8
        source: |
          auto lo
          iface lo inet loopback
      - name: manual
        nic: port7
        source: |
          iface port7 inet manual
      - name: static
        nic: port7
        source: |
          iface port7 inet static
      - name: duplicate
        nic: port7
        source: |
          iface port7 inet manual
          iface port7 inet manual
      - name: dual_stack
        nic: port7
        source: |
          iface port7 inet manual
          iface port7 inet6 manual
  tasks:
    - name: Load host-shaped legacy fixture
      ansible.builtin.set_fact:
        data_link_host_source: "{{ lookup('file', lookup('env', 'DATA_LINK_SOURCE_FIXTURE')) }}"

    - name: Remove legacy feature-owned block from host-shaped fixture
      ansible.builtin.set_fact:
        data_link_host_base: "{{ data_link_host_source | regex_replace(proxmox_vlan_owned_block_pattern, '') }}"

    - name: Collect host-shaped physical NIC IPv4 methods
      ansible.builtin.set_fact:
        data_link_host_methods: >-
          {{
            data_link_host_base
            | regex_findall(
                '(?m)^[ \t]*iface[ \t]+data7[ \t]+inet[ \t]+([^ \t#\r\n]+)'
              )
          }}

    - name: Collect policy-case physical NIC IPv4 methods
      ansible.builtin.set_fact:
        data_link_case_methods: >-
          {{
            data_link_case_methods | default({})
            | combine({
                item.name: (
                  item.source
                  | regex_findall(
                      '(?m)^[ \t]*iface[ \t]+'
                      ~ (item.nic | regex_escape)
                      ~ '[ \t]+inet[ \t]+([^ \t#\r\n]+)'
                    )
                )
              })
          }}
      loop: "{{ data_link_method_cases }}"

    - name: Validate explicit IPv4 method-count policy
      ansible.builtin.assert:
        that:
          - data_link_host_methods == ['manual']
          - data_link_case_methods.absent == []
          - data_link_case_methods.manual == ['manual']
          - data_link_case_methods.static == ['static']
          - data_link_case_methods.duplicate == ['manual', 'manual']
          - data_link_case_methods.dual_stack == ['manual']
          - >-
            (data_link_case_methods.absent | length) == 0
            or
            (
              (data_link_case_methods.absent | length) == 1
              and data_link_case_methods.absent[0] == 'manual'
            )
          - >-
            (data_link_case_methods.manual | length) == 0
            or
            (
              (data_link_case_methods.manual | length) == 1
              and data_link_case_methods.manual[0] == 'manual'
            )
          - >-
            (data_link_case_methods.dual_stack | length) == 0
            or
            (
              (data_link_case_methods.dual_stack | length) == 1
              and data_link_case_methods.dual_stack[0] == 'manual'
            )
          - >-
            not (
              (data_link_case_methods.static | length) == 0
              or
              (
                (data_link_case_methods.static | length) == 1
                and data_link_case_methods.static[0] == 'manual'
              )
            )
          - >-
            not (
              (data_link_case_methods.duplicate | length) == 0
              or
              (
                (data_link_case_methods.duplicate | length) == 1
                and data_link_case_methods.duplicate[0] == 'manual'
              )
            )

    - name: Render host-shaped candidate after legacy block removal
      ansible.builtin.template:
        src: "{{ lookup('env', 'DATA_LINK_TEMPLATE') }}"
        dest: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}/interfaces.host-shaped"
        mode: "0600"
      vars:
        proxmox_vlan_interfaces_without_owned_blocks: "{{ data_link_host_base }}"
        proxmox_vlan_data_nic_emit_manual: "{{ (data_link_host_methods | length) == 0 }}"
        proxmox_vlan_effective:
          data:
            nic: data7
            bridge: lanbr7
            host_ip: null
            bridge_fd: 2
            bridge_vlan_aware: false
            bridge_vids: ""

    - name: Render untagged dual-stack candidate with existing IPv4 declaration
      ansible.builtin.template:
        src: "{{ lookup('env', 'DATA_LINK_TEMPLATE') }}"
        dest: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}/interfaces.untagged"
        mode: "0600"
      vars:
        proxmox_vlan_interfaces_without_owned_blocks: |
          auto lo
          iface lo inet loopback

          iface port7 inet manual
          iface port7 inet6 manual
        proxmox_vlan_data_nic_emit_manual: "{{ (data_link_case_methods.dual_stack | length) == 0 }}"
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
        proxmox_vlan_data_nic_emit_manual: "{{ (data_link_case_methods.absent | length) == 0 }}"
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
DATA_LINK_SOURCE_FIXTURE="${FIXTURE}" \
  ansible-playbook -i localhost, -c local "${RENDER_PLAYBOOK}" >/dev/null

assert.canonical.candidate() {
  local candidate="$1" nic="$2" bridge_name="$3"
  [[ "$(awk -v nic="${nic}" '$1 == "iface" && $2 == nic && $3 == "inet" {count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(awk -v nic="${nic}" '$1 == "iface" && $2 == nic && $3 == "inet" && $4 == "manual" {count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(awk -v nic="${nic}" '$1 == "iface" && $2 == nic && $3 == "inet" && $4 != "manual" {count++} END {print count + 0}' "${candidate}")" == 0 ]]
  [[ "$(awk -v bridge_name="${bridge_name}" '$1 == "iface" && $2 == bridge_name {count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(awk -v bridge_name="${bridge_name}" '$1 == "auto" && $2 == bridge_name {count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(awk -v nic="${nic}" '$1 == "bridge-ports" && $2 == nic {count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(grep -Fxc '# BEGIN ANSIBLE MANAGED BLOCK: ansible-proxmox-data-bridge' "${candidate}")" == 1 ]]
  [[ "$(grep -Fxc '# END ANSIBLE MANAGED BLOCK: ansible-proxmox-data-bridge' "${candidate}")" == 1 ]]
  ! grep -Fq '\n' "${candidate}"
}

assert.canonical.candidate "${HOST_CANDIDATE}" data7 lanbr7
! grep -Fq 'ansible-proxmox-vlan-vmbr1' "${HOST_CANDIDATE}"
assert.canonical.candidate "${UNTAGGED_CANDIDATE}" port7 fabric7
[[ "$(grep -Fxc 'iface port7 inet6 manual' "${UNTAGGED_CANDIDATE}")" == 1 ]]
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
grep -Fq 'proxmox_vlan_data_nic_ipv4_methods' "${VLAN_PLAYBOOK}"
grep -Fq 'nic_nonmanual_count=0' "${VLAN_PLAYBOOK}"
! grep -Fq "~ '\\n'" "${VLAN_PLAYBOOK}"
! grep -Fq 'proxmox_vlan_data_nic_iface_manual_exists' "${VLAN_PLAYBOOK}"
! grep -Eq 'ip link set dev.*master' "${VLAN_PLAYBOOK}"

grep -Fq 'vlan.pending.yml' "${ROOT}/setup/vlan.sh"
grep -Fq 'vlan.applied.yml' "${ROOT}/setup/vlan.sh"
grep -Fq 'vlan.applied.yml' "${ROOT}/setup/network.sh"
grep -Fq 'no physical carrier was detected' "${ROOT}/setup/network-link.sh"

echo "[data_link_policy_test][ok] legacy recovery, explicit IPv4 method counts, rendered candidate structure, and transactional handoff contract"
