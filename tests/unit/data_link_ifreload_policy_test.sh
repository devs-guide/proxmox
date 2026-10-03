#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "${FIXTURE_DIR}"' EXIT
SHIM_DIR="${FIXTURE_DIR}/bin"
SCENARIO_FILE="${FIXTURE_DIR}/scenario"
PLAYBOOK="${FIXTURE_DIR}/ifreload.yml"
TASKS="${ROOT}/ansible/proxmox/tasks/data-link.ifreload.validate.yml"

mkdir -p "${SHIM_DIR}"
cat > "${SHIM_DIR}/ifreload" <<'EOF'
#!/usr/bin/env bash
set -u

syntax=0
no_action=0
for argument in "$@"; do
  case "${argument}" in
    -s|--syntax-check) syntax=1 ;;
    -n|--no-act) no_action=1 ;;
  esac
done

if [[ "${no_action}" -ne 1 ]]; then
  printf '%s\n' 'warning: fabric7: interface not recognized - please check interface configuration' >&2
  exit 0
fi

scenario="$(cat "${DATA_LINK_IFRELOAD_SCENARIO_FILE}")"
case "${scenario}" in
  baseline_dirty)
    printf '%s\n' 'warning: duplicate interface port7 found' >&2
    if [[ "${syntax}" -ne 1 ]]; then
      printf '%s\n' \
        'warning: fabric7: invalid use of bridge attribute (bridge-stp) on non-bridge stanza' \
        'warning: fabric7: invalid use of bridge attribute (bridge-fd) on non-bridge stanza' >&2
    fi
    ;;
  candidate_clean)
    ;;
  candidate_warning)
    if [[ "${syntax}" -ne 1 ]]; then
      printf '%s\n' 'warning: fabric7: interface not recognized - please check interface configuration' >&2
    fi
    ;;
  syntax_failure)
    if [[ "${syntax}" -eq 1 ]]; then
      printf '%s\n' 'syntax error: rejected fixture' >&2
      exit 2
    fi
    ;;
  plan_failure)
    if [[ "${syntax}" -ne 1 ]]; then
      printf '%s\n' 'error: rejected reload plan fixture' >&2
      exit 3
    fi
    ;;
  foreign_baseline)
    printf '%s\n' \
      'warning: otherbr: invalid use of bridge attribute (bridge-stp) on non-bridge stanza' >&2
    ;;
  *)
    printf 'unknown ifreload fixture scenario: %s\n' "${scenario}" >&2
    exit 64
    ;;
esac
EOF
chmod 0755 "${SHIM_DIR}/ifreload"

cat > "${PLAYBOOK}" <<'EOF'
---
- name: Exercise production DATA-Link ifreload validation policy
  hosts: localhost
  connection: local
  gather_facts: false
  environment:
    PATH: "{{ lookup('env', 'DATA_LINK_SHIM_DIR') }}:{{ lookup('env', 'PATH') }}"
    DATA_LINK_IFRELOAD_SCENARIO_FILE: "{{ lookup('env', 'DATA_LINK_SCENARIO_FILE') }}"
  vars:
    proxmox_vlan_fatal_parser_warning_pattern: >-
      (?i)(duplicate interface|invalid use of bridge attribute|interface not recognized|error:|syntax error)
    proxmox_vlan_effective:
      data:
        nic: port7
        bridge: fabric7
    proxmox_vlan_owned_block_count: 1
  tasks:
    - name: Select repairable legacy baseline fixture
      ansible.builtin.copy:
        dest: "{{ lookup('env', 'DATA_LINK_SCENARIO_FILE') }}"
        content: baseline_dirty
        mode: "0600"

    - name: Run production validation for repairable legacy baseline
      ansible.builtin.include_tasks: "{{ lookup('env', 'DATA_LINK_IFRELOAD_TASKS') }}"
      vars:
        proxmox_vlan_ifreload_validation_phase: baseline
        proxmox_vlan_ifreload_validation_result_key: baseline
        proxmox_vlan_ifreload_validation_enforce: false
        proxmox_vlan_ifreload_validation_allow_owned_legacy: true

    - name: Require legacy warnings to be recorded and attributed
      ansible.builtin.assert:
        that:
          - (proxmox_vlan_ifreload_validation_results.baseline.fatal_warnings | length) > 0
          - (proxmox_vlan_ifreload_validation_results.baseline.unapproved_warnings | length) == 0

    - name: Select clean canonical candidate fixture
      ansible.builtin.copy:
        dest: "{{ lookup('env', 'DATA_LINK_SCENARIO_FILE') }}"
        content: candidate_clean
        mode: "0600"

    - name: Run production validation for clean canonical candidate
      ansible.builtin.include_tasks: "{{ lookup('env', 'DATA_LINK_IFRELOAD_TASKS') }}"
      vars:
        proxmox_vlan_ifreload_validation_phase: candidate
        proxmox_vlan_ifreload_validation_result_key: candidate
        proxmox_vlan_ifreload_validation_enforce: true
        proxmox_vlan_ifreload_validation_allow_owned_legacy: false

    - name: Prove a zero-exit candidate warning is rejected
      block:
        - name: Select zero-exit warning fixture
          ansible.builtin.copy:
            dest: "{{ lookup('env', 'DATA_LINK_SCENARIO_FILE') }}"
            content: candidate_warning
            mode: "0600"
        - name: Run production validation for zero-exit warning fixture
          ansible.builtin.include_tasks: "{{ lookup('env', 'DATA_LINK_IFRELOAD_TASKS') }}"
          vars:
            proxmox_vlan_ifreload_validation_phase: candidate_warning
            proxmox_vlan_ifreload_validation_result_key: candidate_warning
            proxmox_vlan_ifreload_validation_enforce: true
            proxmox_vlan_ifreload_validation_allow_owned_legacy: false
      rescue:
        - name: Record zero-exit warning rejection
          ansible.builtin.set_fact:
            data_link_candidate_warning_rejected: true

    - name: Prove syntax failure is rejected
      block:
        - name: Select syntax failure fixture
          ansible.builtin.copy:
            dest: "{{ lookup('env', 'DATA_LINK_SCENARIO_FILE') }}"
            content: syntax_failure
            mode: "0600"
        - name: Run production validation for syntax failure fixture
          ansible.builtin.include_tasks: "{{ lookup('env', 'DATA_LINK_IFRELOAD_TASKS') }}"
          vars:
            proxmox_vlan_ifreload_validation_phase: syntax_failure
            proxmox_vlan_ifreload_validation_result_key: syntax_failure
            proxmox_vlan_ifreload_validation_enforce: true
            proxmox_vlan_ifreload_validation_allow_owned_legacy: false
      rescue:
        - name: Record syntax failure rejection
          ansible.builtin.set_fact:
            data_link_syntax_failure_rejected: true

    - name: Prove reload-plan failure is rejected
      block:
        - name: Select reload-plan failure fixture
          ansible.builtin.copy:
            dest: "{{ lookup('env', 'DATA_LINK_SCENARIO_FILE') }}"
            content: plan_failure
            mode: "0600"
        - name: Run production validation for reload-plan failure fixture
          ansible.builtin.include_tasks: "{{ lookup('env', 'DATA_LINK_IFRELOAD_TASKS') }}"
          vars:
            proxmox_vlan_ifreload_validation_phase: plan_failure
            proxmox_vlan_ifreload_validation_result_key: plan_failure
            proxmox_vlan_ifreload_validation_enforce: true
            proxmox_vlan_ifreload_validation_allow_owned_legacy: false
      rescue:
        - name: Record reload-plan failure rejection
          ansible.builtin.set_fact:
            data_link_plan_failure_rejected: true

    - name: Prove foreign baseline warnings are rejected
      block:
        - name: Select foreign baseline fixture
          ansible.builtin.copy:
            dest: "{{ lookup('env', 'DATA_LINK_SCENARIO_FILE') }}"
            content: foreign_baseline
            mode: "0600"
        - name: Run production validation for foreign baseline fixture
          ansible.builtin.include_tasks: "{{ lookup('env', 'DATA_LINK_IFRELOAD_TASKS') }}"
          vars:
            proxmox_vlan_ifreload_validation_phase: foreign_baseline
            proxmox_vlan_ifreload_validation_result_key: foreign_baseline
            proxmox_vlan_ifreload_validation_enforce: false
            proxmox_vlan_ifreload_validation_allow_owned_legacy: true
      rescue:
        - name: Record foreign baseline rejection
          ansible.builtin.set_fact:
            data_link_foreign_baseline_rejected: true

    - name: Assert complete production ifreload validation contract
      ansible.builtin.assert:
        that:
          - proxmox_vlan_ifreload_validation_results.candidate.syntax_rc == 0
          - proxmox_vlan_ifreload_validation_results.candidate.plan_rc == 0
          - (proxmox_vlan_ifreload_validation_results.candidate.fatal_warnings | length) == 0
          - data_link_candidate_warning_rejected | default(false) | bool
          - data_link_syntax_failure_rejected | default(false) | bool
          - data_link_plan_failure_rejected | default(false) | bool
          - data_link_foreign_baseline_rejected | default(false) | bool
EOF

DATA_LINK_SHIM_DIR="${SHIM_DIR}" \
DATA_LINK_SCENARIO_FILE="${SCENARIO_FILE}" \
DATA_LINK_IFRELOAD_TASKS="${TASKS}" \
  ansible-playbook -i localhost, -c local "${PLAYBOOK}" \
    >"${FIXTURE_DIR}/ansible.log" 2>&1 || {
      cat "${FIXTURE_DIR}/ansible.log" >&2
      exit 1
    }

echo "[data_link_ifreload_policy_test][ok] owned legacy repair and warning-free no-action candidate validation"
