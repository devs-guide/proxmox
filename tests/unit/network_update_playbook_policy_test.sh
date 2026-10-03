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
EMPTY_VARS="${TEST_ROOT}/empty.yml"
mkdir -p "${FAKE_BIN}" "${FACTS_DIR}"

printf '%s\n' '---' '{}' > "${EMPTY_VARS}"
printf 'guest_type\tguest_id\tguest_name\tnet_slot\tdesired_value\treason\n' > "${PLAN_PATH}"
printf 'lxc\t4242\tfixture\tnet1\tname=data0,bridge=br-data,firewall=1,ip=198.51.100.40/24\tadd_static_data_role_no_gateway\n' >> "${PLAN_PATH}"

cat > "${FAKE_BIN}/pct" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  config)
    printf '%s\n' 'net0: name=mgmt0,bridge=br-mgmt,firewall=1,ip=dhcp'
    ;;
  set)
    printf '%s\n' "$*" >> "${NETWORK_TEST_SET_LOG:?}"
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
  local expected_cidr="$1"
  PATH="${FAKE_BIN}:${PATH}" \
  NETWORK_TEST_SET_LOG="${SET_LOG}" \
  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local \
      -e ansible_become=false \
      -e "ansible_python_interpreter_managed=$(command -v python3)" \
      -e "proxmox_feature_group_vars_path=${EMPTY_VARS}" \
      -e "proxmox_network_facts_dir=${FACTS_DIR}" \
      -e "proxmox_network_intent_path=${TEST_ROOT}/missing.intent.yml" \
      -e "proxmox_network_plan_path=${PLAN_PATH}" \
      -e proxmox_network_update_mode=check \
      -e proxmox_network_expected_guest_egress_if=mgmt0 \
      -e proxmox_network_expected_guest_data_if=data0 \
      -e "proxmox_network_expected_data_ipv4_cidr=${expected_cidr}" \
      "${ROOT}/ansible/proxmox/network.update.yml"
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

INVALID_OUTPUT="${TEST_ROOT}/invalid.out"
if run.update.playbook '198.51.100.0/24' > "${INVALID_OUTPUT}" 2>&1; then
  fail 'production playbook accepted a subnet identifier as a host address'
fi
[[ ! -e "${SET_LOG}" ]] || fail 'invalid address validation invoked pct set'

printf '[network_update_playbook_policy_test][ok] production check path, host-address validation, and effective defaults\n'
