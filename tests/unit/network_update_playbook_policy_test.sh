#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  printf '[network_update_playbook_policy_test][error] %s\n' "$*" >&2
  exit 1
}

for contract in \
  'proxmox_network_run_dir' \
  'proxmox_network_preflight_facts_path' \
  'proxmox_network_preflight_json_path' \
  'proxmox_network_intent_path' \
  'proxmox_network_plan_path' \
  'proxmox_network_verify_path' \
  'proxmox_network_update_runtime_facts_path'; do
  if grep -R -E "${contract}:.*\\{\\{[[:space:]]*${contract}[[:space:]]*\\|[[:space:]]*default" \
    "${ROOT}/ansible/proxmox/helper/network.preflight.export.yml" \
    "${ROOT}/ansible/proxmox/network.update.yml" \
    "${ROOT}/ansible/proxmox/network.verify.yml" >/dev/null; then
    fail "self-referential Ansible default remains for ${contract}"
  fi
done

if ! command -v ansible-playbook >/dev/null 2>&1; then
  printf '[network_update_playbook_policy_test][skip] playbook fixture requires ansible-playbook; static default policy passed\n'
  exit 0
fi

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT
FAKE_BIN="${TEST_ROOT}/bin"
FACTS_DIR="${TEST_ROOT}/facts"
PLAN_PATH="${TEST_ROOT}/network.plan.tsv"
SET_LOG="${TEST_ROOT}/pct-set.log"
STATE_PATH="${TEST_ROOT}/pct-state.txt"
VERIFY_PATH="${TEST_ROOT}/network.verify.tsv"
EMPTY_VARS="${TEST_ROOT}/empty.yml"
LXC_NIC_HELPER="${ROOT}/ansible/proxmox/helper/network.lxc_nic.py"
mkdir -p "${FAKE_BIN}" "${FACTS_DIR}"

printf '%s\n' '---' '{}' > "${EMPTY_VARS}"
printf 'guest_type\tguest_id\tguest_name\tnet_slot\tdesired_value\treason\n' > "${PLAN_PATH}"
printf 'lxc\t4242\tfixture\tnet1\tname=data0,bridge=br-data,firewall=1,ip=198.51.100.40/24\tadd_static_data_role_no_gateway\n' >> "${PLAN_PATH}"

cat > "${FAKE_BIN}/pct" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  config)
    printf '%s\n' 'net0: type=veth,bridge=br-mgmt,name=mgmt0,firewall=1,ip=dhcp'
    if [[ -s "${NETWORK_TEST_STATE_PATH:?}" ]]; then
      printf 'net1: %s\n' "$(cat "${NETWORK_TEST_STATE_PATH}")"
    fi
    ;;
  set)
    printf '%s\n' "$*" >> "${NETWORK_TEST_SET_LOG:?}"
    if [[ "${3:-}" == "-net1" ]]; then
      printf '%s\n' 'type=veth,hwaddr=02:00:00:00:00:40,ip=198.51.100.40/24,firewall=1,bridge=br-data,name=data0' > "${NETWORK_TEST_STATE_PATH:?}"
    elif [[ "${3:-}" == "-delete" && "${4:-}" == "net1" ]]; then
      : > "${NETWORK_TEST_STATE_PATH:?}"
    fi
    ;;
  *)
    exit 1
    ;;
esac
EOF
cat > "${FAKE_BIN}/qm" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${FAKE_BIN}/pct" "${FAKE_BIN}/qm"

run.update.playbook() {
  local expected_cidr="$1" mode="${2:-check}"
  PATH="${FAKE_BIN}:${PATH}" \
  NETWORK_TEST_SET_LOG="${SET_LOG}" \
  NETWORK_TEST_STATE_PATH="${STATE_PATH}" \
  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local \
      -e ansible_become=false \
      -e "ansible_python_interpreter_managed=$(command -v python3)" \
      -e "proxmox_feature_group_vars_path=${EMPTY_VARS}" \
      -e "proxmox_network_facts_dir=${FACTS_DIR}" \
      -e "proxmox_network_intent_path=${TEST_ROOT}/missing.intent.yml" \
      -e "proxmox_network_plan_path=${PLAN_PATH}" \
      -e "proxmox_network_lxc_nic_helper_path=${LXC_NIC_HELPER}" \
      -e "proxmox_network_update_mode=${mode}" \
      -e proxmox_network_expected_guest_egress_if=mgmt0 \
      -e proxmox_network_expected_guest_data_if=data0 \
      -e proxmox_network_expected_data_bridge=br-data \
      -e "proxmox_network_expected_data_ipv4_cidr=${expected_cidr}" \
      "${ROOT}/ansible/proxmox/network.update.yml"
}

run.verify.playbook() {
  PATH="${FAKE_BIN}:${PATH}" \
  NETWORK_TEST_SET_LOG="${SET_LOG}" \
  NETWORK_TEST_STATE_PATH="${STATE_PATH}" \
  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local \
      -e ansible_become=false \
      -e "ansible_python_interpreter_managed=$(command -v python3)" \
      -e "proxmox_feature_group_vars_path=${EMPTY_VARS}" \
      -e "proxmox_network_facts_dir=${FACTS_DIR}" \
      -e "proxmox_network_plan_path=${PLAN_PATH}" \
      -e "proxmox_network_verify_path=${VERIFY_PATH}" \
      -e "proxmox_network_lxc_nic_helper_path=${LXC_NIC_HELPER}" \
      -e proxmox_network_expected_guest_egress_if=mgmt0 \
      -e proxmox_network_expected_guest_data_if=data0 \
      -e proxmox_network_expected_data_bridge=br-data \
      -e proxmox_network_expected_data_ipv4_cidr=198.51.100.40/24 \
      "${ROOT}/ansible/proxmox/network.verify.yml"
}

CHECK_OUTPUT="${TEST_ROOT}/check.out"
run.update.playbook '198.51.100.40/24' > "${CHECK_OUTPUT}" \
  || fail 'production network update playbook rejected the valid check fixture'

RUNTIME_PATH="${FACTS_DIR}/network.update.runtime.yml"
[[ -f "${RUNTIME_PATH}" ]] || fail 'derived runtime facts destination was not written'
grep -Eq '^[[:space:]]+mode: "check"$' "${RUNTIME_PATH}" || fail 'runtime mode is not check'
grep -Eq '^[[:space:]]+would_change: true$' "${RUNTIME_PATH}" || fail 'check preview did not report would_change=true'
grep -Eq '^[[:space:]]+changed: false$' "${RUNTIME_PATH}" || fail 'check preview reported a real mutation'
[[ ! -e "${SET_LOG}" ]] || fail 'check mode invoked pct set'

APPLY_OUTPUT="${TEST_ROOT}/apply.out"
run.update.playbook '198.51.100.40/24' apply > "${APPLY_OUTPUT}" \
  || fail 'production network update playbook rejected the valid apply fixture'
grep -Eq '^[[:space:]]+changed: true$' "${RUNTIME_PATH}" || fail 'apply did not record the LXC mutation'
[[ -s "${STATE_PATH}" ]] || fail 'fake Proxmox canonical state was not created'

VERIFY_OUTPUT="${TEST_ROOT}/verify.out"
run.verify.playbook > "${VERIFY_OUTPUT}" \
  || fail 'production verifier rejected reordered Proxmox-generated type/hwaddr fields'
grep -Fq $'\tok\tsemantic LXC DATA-Link definition matches' "${VERIFY_PATH}" \
  || fail 'semantic verification evidence was not persisted'

NOOP_OUTPUT="${TEST_ROOT}/noop.out"
before_set_count="$(wc -l < "${SET_LOG}")"
run.update.playbook '198.51.100.40/24' check > "${NOOP_OUTPUT}" \
  || fail 'canonical existing NIC was not accepted as an idempotent no-op'
after_set_count="$(wc -l < "${SET_LOG}")"
[[ "${before_set_count}" == "${after_set_count}" ]] || fail 'semantic no-op invoked pct set'
grep -Eq '^[[:space:]]+would_change: false$' "${RUNTIME_PATH}" || fail 'semantic no-op reported a pending mutation'
grep -Eq '^[[:space:]]+changed: false$' "${RUNTIME_PATH}" || fail 'semantic no-op reported a real mutation'

printf '%s\n' 'type=veth,hwaddr=02:00:00:00:00:40,ip=198.51.100.40/24,firewall=1,bridge=br-foreign,name=data0' > "${STATE_PATH}"
CONFLICT_OUTPUT="${TEST_ROOT}/conflict.out"
if run.update.playbook '198.51.100.40/24' check > "${CONFLICT_OUTPUT}" 2>&1; then
  fail 'production update accepted a conflicting occupied LXC slot'
fi
grep -Fq 'refuse_live_slot_overwrite' "${CONFLICT_OUTPUT}" || fail 'occupied-slot conflict was not diagnosed'
: > "${STATE_PATH}"

INVALID_OUTPUT="${TEST_ROOT}/invalid.out"
before_invalid_set_count="$(wc -l < "${SET_LOG}")"
if run.update.playbook '198.51.100.0/24' > "${INVALID_OUTPUT}" 2>&1; then
  fail 'production playbook accepted a subnet identifier as a host address'
fi
after_invalid_set_count="$(wc -l < "${SET_LOG}")"
[[ "${before_invalid_set_count}" == "${after_invalid_set_count}" ]] || fail 'invalid address validation invoked pct set'

printf '[network_update_playbook_policy_test][ok] production check/apply/verify semantic path and effective defaults\n'
