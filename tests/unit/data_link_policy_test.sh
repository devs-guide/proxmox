#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "${FIXTURE_DIR}"' EXIT
FIXTURE="${FIXTURE_DIR}/interfaces"
TASKS="${ROOT}/ansible/proxmox/tasks/data-link.candidate.yml"
TEMPLATE="${ROOT}/ansible/proxmox/templates/data-link.interfaces.j2"
RENDER_PLAYBOOK="${FIXTURE_DIR}/render.yml"
HOST_CANDIDATE="${FIXTURE_DIR}/interfaces.host-shaped"

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
- name: Exercise the production DATA-Link candidate task against policy fixtures
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    proxmox_vlan_block_begin: "# BEGIN ANSIBLE MANAGED BLOCK: ansible-proxmox-data-bridge"
    proxmox_vlan_block_end: "# END ANSIBLE MANAGED BLOCK: ansible-proxmox-data-bridge"
    data_link_valid_cases:
      - name: absent
        nic: port8
        bridge: fabric8
        source: |
          auto lo
          iface lo inet loopback
      - name: manual_comment
        nic: port7
        bridge: fabric7
        source: |
          iface port7 inet manual # retained declaration
      - name: dual_stack
        nic: port7
        bridge: fabric9
        source: |
          iface port7 inet manual
          iface port7 inet6 manual
      - name: tabs_crlf
        nic: port9
        bridge: fabric10
        source: "iface\tport9\tinet\tmanual\r\niface\tport9\tinet6\tmanual\r\n"
      - name: legacy_block_crlf
        nic: port11
        bridge: fabric11
        source: "# BEGIN ANSIBLE MANAGED BLOCK: ansible-proxmox-vlan-vmbr1\r\niface port11 inet manual\r\n# END ANSIBLE MANAGED BLOCK: ansible-proxmox-vlan-vmbr1\r\niface port11 inet manual\r\n"
      - name: metachar_name
        nic: port.7+safe
        bridge: fabric.7+safe
        source: |
          iface port.7+safe inet manual
  tasks:
    - name: Load host-shaped legacy fixture
      ansible.builtin.set_fact:
        data_link_host_source: "{{ lookup('file', lookup('env', 'DATA_LINK_SOURCE_FIXTURE')) }}"

    - name: Run canonical production task for host-shaped fixture
      ansible.builtin.include_tasks: "{{ lookup('env', 'DATA_LINK_TASKS') }}"
      vars:
        proxmox_vlan_candidate_source_text: "{{ data_link_host_source }}"
        proxmox_vlan_candidate_result_key: host
        proxmox_vlan_candidate_dir: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}"
        proxmox_vlan_candidate_path: "{{ lookup('env', 'DATA_LINK_HOST_CANDIDATE') }}"
        proxmox_vlan_candidate_template_path: "{{ lookup('env', 'DATA_LINK_TEMPLATE') }}"
        proxmox_vlan_effective:
          data:
            nic: data7
            bridge: lanbr7
            host_ip: null
            bridge_fd: 2
            bridge_vlan_aware: false
            bridge_vids: ""

    - name: Run canonical production task for accepted syntax variants
      ansible.builtin.include_tasks: "{{ lookup('env', 'DATA_LINK_TASKS') }}"
      vars:
        proxmox_vlan_candidate_source_text: "{{ data_link_case.source }}"
        proxmox_vlan_candidate_result_key: "{{ data_link_case.name }}"
        proxmox_vlan_candidate_dir: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}"
        proxmox_vlan_candidate_path: >-
          {{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}/interfaces.{{ data_link_case.name }}
        proxmox_vlan_candidate_template_path: "{{ lookup('env', 'DATA_LINK_TEMPLATE') }}"
        proxmox_vlan_effective:
          data:
            nic: "{{ data_link_case.nic }}"
            bridge: "{{ data_link_case.bridge }}"
            host_ip: null
            bridge_fd: 2
            bridge_vlan_aware: false
            bridge_vids: ""
      loop: "{{ data_link_valid_cases }}"
      loop_control:
        loop_var: data_link_case
        label: "{{ data_link_case.name }}"

    - name: Prove static physical configuration is rejected by production policy
      block:
        - name: Run canonical production task for static fixture
          ansible.builtin.include_tasks: "{{ lookup('env', 'DATA_LINK_TASKS') }}"
          vars:
            proxmox_vlan_candidate_source_text: "iface port7 inet static\n"
            proxmox_vlan_candidate_result_key: static
            proxmox_vlan_candidate_render: false
            proxmox_vlan_candidate_dir: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}"
            proxmox_vlan_candidate_path: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}/unused.static"
            proxmox_vlan_candidate_template_path: "{{ lookup('env', 'DATA_LINK_TEMPLATE') }}"
            proxmox_vlan_effective:
              data:
                nic: port7
                bridge: fabric11
      rescue:
        - name: Record static policy rejection
          ansible.builtin.set_fact:
            data_link_static_rejected: true

    - name: Prove duplicate physical configuration is rejected by production policy
      block:
        - name: Run canonical production task for duplicate fixture
          ansible.builtin.include_tasks: "{{ lookup('env', 'DATA_LINK_TASKS') }}"
          vars:
            proxmox_vlan_candidate_source_text: |
              iface port7 inet manual
              iface port7 inet manual
            proxmox_vlan_candidate_result_key: duplicate
            proxmox_vlan_candidate_render: false
            proxmox_vlan_candidate_dir: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}"
            proxmox_vlan_candidate_path: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}/unused.duplicate"
            proxmox_vlan_candidate_template_path: "{{ lookup('env', 'DATA_LINK_TEMPLATE') }}"
            proxmox_vlan_effective:
              data:
                nic: port7
                bridge: fabric12
      rescue:
        - name: Record duplicate policy rejection
          ansible.builtin.set_fact:
            data_link_duplicate_rejected: true

    - name: Prove foreign bridge configuration is rejected by production policy
      block:
        - name: Run canonical production task for foreign bridge fixture
          ansible.builtin.include_tasks: "{{ lookup('env', 'DATA_LINK_TASKS') }}"
          vars:
            proxmox_vlan_candidate_source_text: |
              iface port7 inet manual
              auto fabric13
              iface fabric13 inet manual
            proxmox_vlan_candidate_result_key: foreign_bridge
            proxmox_vlan_candidate_render: false
            proxmox_vlan_candidate_dir: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}"
            proxmox_vlan_candidate_path: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}/unused.foreign"
            proxmox_vlan_candidate_template_path: "{{ lookup('env', 'DATA_LINK_TEMPLATE') }}"
            proxmox_vlan_effective:
              data:
                nic: port7
                bridge: fabric13
      rescue:
        - name: Record foreign bridge policy rejection
          ansible.builtin.set_fact:
            data_link_foreign_bridge_rejected: true

    - name: Prove malformed owned blocks are rejected by production policy
      block:
        - name: Run canonical production task for malformed block fixture
          ansible.builtin.include_tasks: "{{ lookup('env', 'DATA_LINK_TASKS') }}"
          vars:
            proxmox_vlan_candidate_source_text: |
              iface port7 inet manual
              # BEGIN ANSIBLE MANAGED BLOCK: ansible-proxmox-data-bridge
              auto fabric14
            proxmox_vlan_candidate_result_key: malformed_block
            proxmox_vlan_candidate_render: false
            proxmox_vlan_candidate_dir: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}"
            proxmox_vlan_candidate_path: "{{ lookup('env', 'DATA_LINK_FIXTURE_DIR') }}/unused.malformed"
            proxmox_vlan_candidate_template_path: "{{ lookup('env', 'DATA_LINK_TEMPLATE') }}"
            proxmox_vlan_effective:
              data:
                nic: port7
                bridge: fabric14
      rescue:
        - name: Record malformed block policy rejection
          ansible.builtin.set_fact:
            data_link_malformed_block_rejected: true

    - name: Assert canonical parser and rejection results
      ansible.builtin.assert:
        that:
          - proxmox_vlan_candidate_results.host.methods == ['manual']
          - "'ma' not in proxmox_vlan_candidate_results.host.methods"
          - proxmox_vlan_candidate_results.absent.methods == []
          - proxmox_vlan_candidate_results.absent.emit_manual | bool
          - proxmox_vlan_candidate_results.manual_comment.methods == ['manual']
          - proxmox_vlan_candidate_results.dual_stack.methods == ['manual']
          - proxmox_vlan_candidate_results.tabs_crlf.methods == ['manual']
          - proxmox_vlan_candidate_results.legacy_block_crlf.methods == ['manual']
          - proxmox_vlan_candidate_results.metachar_name.methods == ['manual']
          - proxmox_vlan_candidate_results.static.methods == ['static']
          - not (proxmox_vlan_candidate_results.static.policy_valid | bool)
          - proxmox_vlan_candidate_results.duplicate.methods == ['manual', 'manual']
          - not (proxmox_vlan_candidate_results.duplicate.policy_valid | bool)
          - (proxmox_vlan_candidate_results.foreign_bridge.foreign_bridge_references | int) == 2
          - data_link_static_rejected | default(false) | bool
          - data_link_duplicate_rejected | default(false) | bool
          - data_link_foreign_bridge_rejected | default(false) | bool
          - data_link_malformed_block_rejected | default(false) | bool
EOF

DATA_LINK_TASKS="${TASKS}" \
DATA_LINK_TEMPLATE="${TEMPLATE}" \
DATA_LINK_FIXTURE_DIR="${FIXTURE_DIR}" \
DATA_LINK_SOURCE_FIXTURE="${FIXTURE}" \
DATA_LINK_HOST_CANDIDATE="${HOST_CANDIDATE}" \
  ansible-playbook -i localhost, -c local "${RENDER_PLAYBOOK}" \
    >"${FIXTURE_DIR}/ansible.log" 2>&1 || {
      cat "${FIXTURE_DIR}/ansible.log" >&2
      exit 1
    }

assert.canonical.candidate() {
  local candidate="$1" nic="$2" bridge_name="$3"
  [[ "$(awk -v nic="${nic}" '$1 == "iface" && $2 == nic && $3 == "inet" {count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(awk -v nic="${nic}" '$1 == "iface" && $2 == nic && $3 == "inet" {method=$4; gsub(sprintf("%c", 13), "", method); if (method == "manual") count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(awk -v bridge_name="${bridge_name}" '$1 == "iface" && $2 == bridge_name {count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(awk -v nic="${nic}" '$1 == "bridge-ports" && $2 == nic {count++} END {print count + 0}' "${candidate}")" == 1 ]]
  [[ "$(grep -Fxc '# BEGIN ANSIBLE MANAGED BLOCK: ansible-proxmox-data-bridge' "${candidate}")" == 1 ]]
  [[ "$(grep -Fxc '# END ANSIBLE MANAGED BLOCK: ansible-proxmox-data-bridge' "${candidate}")" == 1 ]]
  ! grep -Fq '\n' "${candidate}"
}

assert.canonical.candidate "${HOST_CANDIDATE}" data7 lanbr7
! grep -Fq 'ansible-proxmox-vlan-vmbr1' "${HOST_CANDIDATE}"
assert.canonical.candidate "${FIXTURE_DIR}/interfaces.tabs_crlf" port9 fabric10
assert.canonical.candidate "${FIXTURE_DIR}/interfaces.metachar_name" port.7+safe fabric.7+safe
[[ "$(grep -Fxc 'iface port7 inet6 manual' "${FIXTURE_DIR}/interfaces.dual_stack")" == 1 ]]

VLAN_PLAYBOOK="${ROOT}/ansible/proxmox/vlan.yml"
grep -Fq 'tasks/data-link.candidate.yml' "${VLAN_PLAYBOOK}"
grep -Fq 'Parse complete DATA-Link candidate interface list' "${VLAN_PLAYBOOK}"
grep -Fq 'duplicate interface|invalid use of bridge attribute|interface not recognized' "${VLAN_PLAYBOOK}"
! grep -Fq 'proxmox_vlan_owned_block_pattern' "${VLAN_PLAYBOOK}"
! grep -Eq 'ip link set dev.*master' "${VLAN_PLAYBOOK}"

grep -Fq 'proxmox/tasks/data-link.candidate.yml' "${ROOT}/setup/vlan.sh"
grep -Fq 'vlan.pending.yml' "${ROOT}/setup/vlan.sh"
grep -Fq 'vlan.applied.yml' "${ROOT}/setup/vlan.sh"
grep -Fq 'vlan.applied.yml' "${ROOT}/setup/network.sh"
grep -Fq 'no physical carrier was detected' "${ROOT}/setup/network-link.sh"

echo "[data_link_policy_test][ok] production parser source, exact methods, syntax variants, rejection policy, and rendered candidate contract"
