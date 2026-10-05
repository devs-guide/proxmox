#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROXMOX_NETWORK_SOURCE_ONLY=1
# shellcheck source=setup/network.sh
source "${ROOT}/setup/network.sh"

fail() {
  printf '[network_update_transaction_policy_test][error] %s\n' "$*" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT
FAKE_BIN="${TEST_ROOT}/bin"
STATE_PATH="${TEST_ROOT}/pct-state.txt"
SET_LOG="${TEST_ROOT}/pct-set.log"
mkdir -p "${FAKE_BIN}"

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
    if [[ "${3:-}" == "-delete" && "${4:-}" == "net1" ]]; then
      : > "${NETWORK_TEST_STATE_PATH:?}"
    else
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
EOF
cat > "${FAKE_BIN}/qm" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${FAKE_BIN}/pct" "${FAKE_BIN}/qm"
export PATH="${FAKE_BIN}:${PATH}"
export NETWORK_TEST_STATE_PATH="${STATE_PATH}"
export NETWORK_TEST_SET_LOG="${SET_LOG}"

FACTS_DIR="${TEST_ROOT}/facts"
NETWORK_PLAN_PATH="${FACTS_DIR}/network.plan.tsv"
NETWORK_VERIFY_PATH="${FACTS_DIR}/network.verify.tsv"
NETWORK_UPDATE_STATUS_PATH="${FACTS_DIR}/network.update.status.yml"
NETWORK_TRANSACTION_PATH="${FACTS_DIR}/network.transaction.tsv"
NETWORK_ROLLBACK_PATH="${FACTS_DIR}/network.rollback.tsv"
NETWORK_LXC_NIC_HELPER_PATH="${ROOT}/ansible/proxmox/helper/network.lxc_nic.py"
LXC_TSV_PATH="${TEST_ROOT}/network.lxc.tsv"
RUN_DIR="${TEST_ROOT}/snapshot"
EXPECTED_DATA_BRIDGE='br-data'
EXPECTED_ADMIN_BRIDGE='br-mgmt'
FEATURE_INTERACTIVE=0
PROXMOX_NETWORK_UPDATE_MODE=apply
PROXMOX_NETWORK_UPDATE_AUTO_APPLY=0
mkdir -p "${FACTS_DIR}" "${RUN_DIR}"

printf 'guest_type\tguest_id\tguest_name\tnet_slot\tdesired_value\treason\n' > "${NETWORK_PLAN_PATH}"
printf 'lxc\t4242\tfixture\tnet1\tname=data0,bridge=br-data,firewall=1,ip=198.51.100.40/24\tadd_static_data_role_no_gateway\n' >> "${NETWORK_PLAN_PATH}"
printf 'guest_type\tguest_id\tguest_name\tstatus\tnet_slot\tguest_if\tbridge\tvlan_tag\ttrunks\tfirewall\tmtu\tip_hint\tgw_hint\traw\n' > "${LXC_TSV_PATH}"
printf 'lxc\t4242\tfixture\trunning\tnet0\tmgmt0\tbr-mgmt\t-\t-\t1\t1500\tdhcp\t192.0.2.1\tname=mgmt0,bridge=br-mgmt,firewall=1,ip=dhcp\n' >> "${LXC_TSV_PATH}"
printf 'lxc\t4242\tfixture\trunning\tnet1\tdata0\tbr-data\t-\t-\t1\t1500\t198.51.100.40/24\t-\ttype=veth,bridge=br-data,name=data0,firewall=1,ip=198.51.100.40/24\n' >> "${LXC_TSV_PATH}"
cat > "${NETWORK_UPDATE_STATUS_PATH}" <<EOF
---
proxmox_network_update_status:
  status: "failed"
  phase: "verify"
EOF

printf '%s\n' 'type=veth,hwaddr=02:00:00:00:00:40,ip=198.51.100.40/24,firewall=1,bridge=br-data,name=data0' > "${STATE_PATH}"
detect.pending.network.recovery || fail 'matching canonical NIC was not recognized as a pending recovery'
[[ "${NETWORK_RECOVERY_MODE}" -eq 1 ]] || fail 'recovery mode was not enabled'
[[ "${EXPECTED_GUEST_ADMIN_IF}" == 'mgmt0' ]] || fail 'management interface was not preserved during recovery'
[[ "${EXPECTED_GUEST_DATA_IF}" == 'data0' ]] || fail 'data interface was not restored from the plan'
[[ "${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR}" == '198.51.100.40/24' ]] || fail 'data CIDR was not restored from the plan'

write.network.transaction.journal recovery || fail 'matching recovery transaction was not journaled'
rollback.network.update.plan || fail 'semantic rollback rejected generated Proxmox fields'
[[ ! -s "${STATE_PATH}" ]] || fail 'semantic rollback did not remove the feature-owned NIC'
grep -Fq $'\tdeleted\tsemantically matching feature-owned NIC was removed' "${NETWORK_ROLLBACK_PATH}" \
  || fail 'successful rollback evidence was not recorded'

printf '%s\n' 'type=veth,hwaddr=02:00:00:00:00:40,ip=198.51.100.40/24,firewall=1,bridge=br-foreign,name=data0' > "${STATE_PATH}"
if rollback.network.update.plan; then
  fail 'rollback deleted or accepted an operator-conflicting NIC'
fi
[[ -s "${STATE_PATH}" ]] || fail 'conflicting NIC was destructively removed'
grep -Fq $'\tconflict\tlive NIC differs from the transaction:' "${NETWORK_ROLLBACK_PATH}" \
  || fail 'rollback conflict evidence was not recorded'

if write.network.transaction.journal new; then
  fail 'new transaction accepted an occupied slot after preview'
fi

printf '[network_update_transaction_policy_test][ok] recovery ownership and fail-closed rollback policy\n'
