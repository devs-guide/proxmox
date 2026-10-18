#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf '[lxc_transfer_policy_test][error] %s\n' "$*" >&2; exit 1; }
ok() { printf '[lxc_transfer_policy_test][ok] %s\n' "$*"; }

export PROXMOX_LXC_TRANSFER_SOURCE_ONLY=1
# shellcheck source=setup/lxc/transfer.sh
source "${ROOT}/setup/lxc/transfer.sh"

[[ "$(normalize.network '10.23.45.9/24')" == '10.23.45.0/24' ]] \
  || fail 'host-form CIDR was not canonicalized to the complete network'
[[ "$(normalize.network '172.24.19.61/20')" == '172.24.16.0/20' ]] \
  || fail 'non-/24 private CIDR was not canonicalized'
! normalize.network '10.23.45.9/32' >/dev/null 2>&1 \
  || fail 'peer-specific /32 policy was accepted'
! normalize.network '8.8.8.0/24' >/dev/null 2>&1 \
  || fail 'public network was accepted as an isolated DATA-Link'
ok 'production full-CIDR normalization and rejection policy'

parsed="$(normalize.interface '192.168.77.31/24')"
[[ "$(printf '%s\n' "${parsed}" | sed -n '1p')" == '192.168.77.31/24' \
  && "$(printf '%s\n' "${parsed}" | sed -n '2p')" == '192.168.77.31' \
  && "$(printf '%s\n' "${parsed}" | sed -n '3p')" == '192.168.77.0/24' ]] \
  || fail 'production interface parser returned the wrong address/network tuple'
ok 'production interface parser'

key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureOnlyNotASecret'
expected="$(python3 - "${key}" <<'PY'
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode()).hexdigest())
PY
)"
[[ "$(client.id "${key}")" == "${expected}" ]] || fail 'client registry identifier is not deterministic'
ok 'deterministic public-key registry identifier'

fixture_dir="$(mktemp -d)"
trap 'rm -rf "${fixture_dir}"' EXIT
FACTS_DIR="${fixture_dir}/facts"
SELECTION_PATH="${FACTS_DIR}/selection.yml"
DATA_INTERFACE='ens_fixture'
LOCAL_CIDR='172.29.41.7/24'
LOCAL_ADDRESS='172.29.41.7'
ALLOW_CIDR='172.29.41.0/24'
TRANSFER_ROOT='/fixture/storage root'
ACCESS_GROUP='fixture_group'
SERVICE_USER='fixture_transfer'
PORT='2222'
write.selection
python3 - "${SELECTION_PATH}" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())["proxmox_lxc_transfer_operator_selection"]
expected = {
    "confirmed": True, "data_interface": "ens_fixture", "local_cidr": "172.29.41.7/24",
    "allow_cidr": "172.29.41.0/24", "transfer_root": "/fixture/storage root",
    "access_group": "fixture_group", "service_user": "fixture_transfer", "port": 2222,
    "iperf_port": 5201,
}
assert all(data[key] == value for key, value in expected.items())
PY

CONFIG_DIR="${fixture_dir}/config"
BUNDLE_OUT="${fixture_dir}/bundle.json"
mkdir -p "${CONFIG_DIR}"
ssh-keygen -q -t ed25519 -N '' -C fixture-client -f "${CONFIG_DIR}/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -C fixture-host -f "${CONFIG_DIR}/ssh_host_ed25519_key"
generate.bundle >/dev/null
python3 - "${BUNDLE_OUT}" <<'PY'
import ipaddress, json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert data["schema_version"] == 1 and data["kind"] == "server-peer"
assert ipaddress.ip_address(data["endpoint"]) in ipaddress.ip_network(data["allow_cidr"])
assert data["port"] == 2222 and data["service_user"] == "fixture_transfer"
assert data["client_public_key"].startswith("ssh-ed25519 ")
assert data["server_host_public_key"].startswith("ssh-ed25519 ")
assert "PRIVATE" not in pathlib.Path(sys.argv[1]).read_text()
PY
ok 'production selection and public pairing-bundle renderers'

client_bundle="${fixture_dir}/client.json"
python3 - "${client_bundle}" "${CONFIG_DIR}/id_ed25519.pub" <<'PY'
import json, pathlib, sys
fields = pathlib.Path(sys.argv[2]).read_text().split()
data = {"schema_version": 1, "kind": "client", "allow_cidr": "172.29.41.0/24",
        "service_user": "fixture_transfer", "client_public_key": " ".join(fields[:2])}
pathlib.Path(sys.argv[1]).write_text(json.dumps(data) + "\n")
PY
PEER_BUNDLE="${client_bundle}"
parse.peer.bundle
[[ "${#PEER_FIELDS[@]}" -eq 8 && "${PEER_FIELDS[0]}" == client && "${PEER_FIELDS[1]}" == - && "${PEER_FIELDS[6]}" == - ]] \
  || fail 'client-only bundle did not preserve the production parser field contract'
ok 'additional LAN client bundle parser'

for forbidden in '10.10.0.4' '10.10.0.10' '10.10.0.100' '10.0.0.4' '10.0.0.172' dragonfruit; do
  if grep -Fq -- "${forbidden}" \
    "${ROOT}/setup/lxc/transfer.sh" \
    "${ROOT}/ansible/proxmox/container/rsync.peer.yml" \
    "${ROOT}/ansible/proxmox/tasks/lxc.transfer.ufw.yml" \
    "${ROOT}/cli/ssh/peer.sh" \
    "${ROOT}/cli/rsync/tree.sh" \
    "${ROOT}/cli/network/speed.sh" \
    "${ROOT}/setup/lxc/storage.sh" \
    "${ROOT}/RELEASE_NOTES.md" \
    "${ROOT}/docs/release/0.0.8.md" \
    "${ROOT}/docs/setup/lxc/transfer.md"; then
    fail "site topology leaked into production feature or release source: ${forbidden}"
  fi
done
ok 'production source remains topology-neutral'

grep -Fq '$4 == endpoint' "${ROOT}/setup/lxc/transfer.sh" \
  || fail 'listener verification must compare the local-address column exactly'
grep -Fq '$4 ~ /^0\.0\.0\.0:/' "${ROOT}/setup/lxc/transfer.sh" \
  || fail 'listener verification must reject only a wildcard local-address column'
printf '%s\n' \
  'LISTEN 0 128 172.29.41.7:22 0.0.0.0:*' \
  | awk -v endpoint='172.29.41.7:22' '$4 == endpoint {found=1} $4 ~ /^0\.0\.0\.0:/ {bad=1} END {exit(found && !bad ? 0 : 1)}' \
  || fail 'listener verification rejected a peer-column wildcard'
if printf '%s\n' \
  'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*' \
  | awk -v endpoint='172.29.41.7:22' '$4 == endpoint {found=1} $4 ~ /^0\.0\.0\.0:/ {bad=1} END {exit(found && !bad ? 0 : 1)}'; then
  fail 'listener verification accepted a wildcard local listener'
fi
ok 'listener verification distinguishes local and peer address columns'

grep -Fq 'dest: "{{ proxmox_lxc_transfer_effective.config_dir }}/authorized-keys-command"' \
  "${ROOT}/ansible/proxmox/container/rsync.peer.yml" \
  || fail 'restricted-key reader is not installed below the root-owned feature configuration tree'
grep -Fq 'AuthorizedKeysCommand {{ proxmox_lxc_transfer_effective.config_dir }}/authorized-keys-command %u' \
  "${ROOT}/ansible/proxmox/container/rsync.peer.yml" \
  || fail 'sshd does not use the root-owned restricted-key reader path'
if grep -Fq 'AuthorizedKeysCommand /usr/local/libexec/proxmox-transfer-authorized-keys' \
  "${ROOT}/ansible/proxmox/container/rsync.peer.yml"; then
  fail 'sshd still depends on legacy /usr/local ownership for key authentication'
fi
ok 'authorized-keys command remains safe on legacy shifted root filesystems'

for temp_safe_script in setup/lxc/transfer.sh cli/network/speed.sh; do
  grep -Fq 'unset TMP TEMP' "${ROOT}/${temp_safe_script}" \
    || fail "${temp_safe_script} does not discard inherited host temp paths"
  grep -Fq 'export TMPDIR=/tmp' "${ROOT}/${temp_safe_script}" \
    || fail "${temp_safe_script} does not select the LXC sticky temp directory"
done
grep -Fq 'PROXMOX_LXC_TRANSFER_IPERF_STREAMS:-1' "${ROOT}/cli/network/speed.sh" \
  || fail 'the basic iperf3 check is not single-stream by default'
ok 'LXC operations sanitize host temp paths and use a basic speed-test default'

grep -Fq 'password: "*"' "${ROOT}/ansible/proxmox/container/rsync.peer.yml" \
  || fail 'new restricted transfer accounts do not use an impossible password hash'
grep -Fq 'update_password: on_create' "${ROOT}/ansible/proxmox/container/rsync.peer.yml" \
  || fail 'new restricted transfer account password policy is not creation-only'
if grep -Fq 'password: "NP"' "${ROOT}/ansible/proxmox/container/rsync.peer.yml"; then
  fail 'new transfer accounts still use an invalid literal password hash'
fi
if grep -Fq 'password_lock: true' "${ROOT}/ansible/proxmox/container/rsync.peer.yml"; then
  fail 'new transfer accounts are locked out of the isolated UsePAM=no SSH daemon'
fi
ok 'new restricted transfer accounts disable password login without blocking keys'

grep -Fq -- '- screen' "${ROOT}/ansible/proxmox/container/rsync.peer.yml" \
  || fail 'managed transfer jobs do not install GNU Screen'
ok 'managed background transfer dependency'

operation_dir="${fixture_dir}/operation"
mkdir -p "${operation_dir}/bin" "${operation_dir}/storage/source" "${operation_dir}/storage/destination"
printf 'fixture\n' > "${operation_dir}/storage/source/file.txt"
python3 - "${operation_dir}/selection.json" "${operation_dir}/storage" <<'PY'
import json, pathlib, sys
path, root = sys.argv[1:]
data = {"proxmox_lxc_transfer_operator_selection": {
    "confirmed": True, "source": "setup/lxc/transfer.sh", "data_interface": "ens_fixture",
    "local_cidr": "172.29.41.7/24", "allow_cidr": "172.29.41.0/24",
    "transfer_root": root, "access_group": "fixture_group", "service_user": "fixture_transfer",
    "port": 2222, "iperf_port": 5201,
}}
pathlib.Path(path).write_text(json.dumps(data) + "\n")
PY
cat > "${operation_dir}/bin/rsync" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "${PROXMOX_TEST_ARGUMENTS}"
SH
cat > "${operation_dir}/bin/ip" <<'SH'
#!/bin/sh
printf '1: ens_fixture    inet 172.29.41.7/24 scope global ens_fixture\n'
SH
cat > "${operation_dir}/bin/iperf3" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "${PROXMOX_TEST_ARGUMENTS}"
SH
cat > "${operation_dir}/bin/ssh" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "${PROXMOX_TEST_ARGUMENTS}"
SH
cat > "${operation_dir}/ssh-wrapper" <<'SH'
#!/bin/sh
exit 0
SH
chmod 0755 "${operation_dir}/bin/rsync" "${operation_dir}/bin/ip" "${operation_dir}/bin/iperf3" \
  "${operation_dir}/bin/ssh" "${operation_dir}/ssh-wrapper"
printf 'fixture-host-key\n' > "${CONFIG_DIR}/known_hosts"

PATH="${operation_dir}/bin:${PATH}" \
PROXMOX_TEST_ARGUMENTS="${operation_dir}/ssh-check.args" \
PROXMOX_LXC_TRANSFER_CONFIG_DIR="${CONFIG_DIR}" \
PROXMOX_LXC_TRANSFER_SELECTION_PATH="${operation_dir}/selection.json" \
  "${ROOT}/cli/ssh/peer.sh" check 172.29.41.8
grep -Fxq -- 'fixture_transfer@172.29.41.8' "${operation_dir}/ssh-check.args" \
  || fail 'SSH check omitted the selected service user and operator-entered peer'
grep -Fxq -- '2222' "${operation_dir}/ssh-check.args" \
  || fail 'SSH check omitted the saved non-default port'
grep -Fxq -- 'proxmox-transfer-check' "${operation_dir}/ssh-check.args" \
  || fail 'SSH check omitted the fixed server handshake command'
ok 'key-only pinned-host SSH pairing check'

for action in push verify-push backup-push verify-backup-push; do
  arguments="${operation_dir}/${action}.args"
  PATH="${operation_dir}/bin:${PATH}" \
  PROXMOX_TEST_ARGUMENTS="${arguments}" \
  PROXMOX_LXC_TRANSFER_SELECTION_PATH="${operation_dir}/selection.json" \
  PROXMOX_LXC_TRANSFER_SSH_WRAPPER="${operation_dir}/ssh-wrapper" \
    "${ROOT}/cli/rsync/tree.sh" "${action}" "${operation_dir}/storage/source/" '172.29.41.8:chosen/destination/'
  ! grep -Eq -- '--delete|--remove-source-files' "${arguments}" || fail "${action} emitted a destructive rsync option"
  ! grep -Fxq -- '--protect-args' "${arguments}" || fail "${action} emitted rrsync-incompatible server option -s"
done
for action in pull verify-pull backup-pull verify-backup-pull; do
  arguments="${operation_dir}/${action}.args"
  PATH="${operation_dir}/bin:${PATH}" \
  PROXMOX_TEST_ARGUMENTS="${arguments}" \
  PROXMOX_LXC_TRANSFER_SELECTION_PATH="${operation_dir}/selection.json" \
  PROXMOX_LXC_TRANSFER_SSH_WRAPPER="${operation_dir}/ssh-wrapper" \
    "${ROOT}/cli/rsync/tree.sh" "${action}" '172.29.41.8:chosen/source/' "${operation_dir}/storage/destination/"
  ! grep -Eq -- '--delete|--remove-source-files' "${arguments}" || fail "${action} emitted a destructive rsync option"
  ! grep -Fxq -- '--protect-args' "${arguments}" || fail "${action} emitted rrsync-incompatible server option -s"
done
grep -Fxq -- '--partial' "${operation_dir}/push.args" || fail 'push did not retain restartable partial-copy behavior'
grep -Fxq -- '--partial' "${operation_dir}/pull.args" || fail 'pull did not retain restartable partial-copy behavior'
grep -Fxq -- '--partial' "${operation_dir}/backup-push.args" || fail 'backup-push did not retain restartable partial-copy behavior'
grep -Fxq -- '--partial' "${operation_dir}/backup-pull.args" || fail 'backup-pull did not retain restartable partial-copy behavior'
! grep -Fxq -- '--dry-run' "${operation_dir}/push.args" || fail 'push unexpectedly became a dry run'
! grep -Fxq -- '--dry-run' "${operation_dir}/pull.args" || fail 'pull unexpectedly became a dry run'
grep -Fxq -- '--dry-run' "${operation_dir}/verify-push.args" || fail 'verify-push is not a dry run'
grep -Fxq -- '--checksum' "${operation_dir}/verify-push.args" || fail 'verify-push does not compare checksums'
grep -Fxq -- '--dry-run' "${operation_dir}/verify-pull.args" || fail 'verify-pull is not a dry run'
grep -Fxq -- '--checksum' "${operation_dir}/verify-pull.args" || fail 'verify-pull does not compare checksums'
for action in backup-push backup-pull verify-backup-push verify-backup-pull; do
  arguments="${operation_dir}/${action}.args"
  grep -Fxq -- '-rltHXS' "${arguments}" || fail "${action} omitted the ACL-safe metadata policy"
  grep -Fxq -- '--no-perms' "${arguments}" || fail "${action} can restore source modes"
  grep -Fxq -- '--no-acls' "${arguments}" || fail "${action} can restore source ACLs"
  grep -Fxq -- '--chmod=Du+rwx,Dg+rwx,Fu+rw,Fg+rw' "${arguments}" \
    || fail "${action} omitted the inherited ACL mask policy"
  ! grep -Fxq -- '-rlptHAXS' "${arguments}" || fail "${action} retained source permission/ACL preservation"
done
grep -Fxq -- '--dry-run' "${operation_dir}/verify-backup-push.args" \
  || fail 'verify-backup-push is not a dry run'
grep -Fxq -- '--checksum' "${operation_dir}/verify-backup-push.args" \
  || fail 'verify-backup-push does not compare checksums'
ok 'metadata-preserving and ACL-safe non-deleting transfer arguments'

job_state_dir="${operation_dir}/jobs"
job_log_dir="${operation_dir}/job-logs"
mkdir -p "${job_state_dir}" "${job_log_dir}"
printf '  469.91G  22%%  100.50MB/s    1:17:52 (xfr#913792, ir-chk=1000/4076320)\r' \
  > "${job_log_dir}/fixture-job.log"
python3 - "${job_state_dir}/fixture-job.json" "${job_log_dir}/fixture-job.log" <<'PY'
import json, pathlib, sys
state, log = sys.argv[1:]
pathlib.Path(state).write_text(json.dumps({
    "schema_version": 1,
    "job": "fixture-job",
    "operation": "backup-push",
    "source": "/fixture/source/",
    "destination": "172.29.41.8:fixture/",
    "screen_session": "pxfer-fixture-job",
    "status": "completed",
    "runner_pid": 100,
    "rsync_pid": 101,
    "started_at": "2026-01-01T00:00:00Z",
    "started_epoch": 100,
    "finished_at": "2026-01-01T00:01:40Z",
    "finished_epoch": 200,
    "exit_code": 0,
    "log_path": log,
}) + "\n")
PY
status_json="$(
  PROXMOX_LXC_TRANSFER_JOB_STATE_DIR="${job_state_dir}" \
  PROXMOX_LXC_TRANSFER_JOB_LOG_DIR="${job_log_dir}" \
    "${ROOT}/cli/rsync/tree.sh" status fixture-job --output json
)"
python3 - "${status_json}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["status"] == "completed"
assert data["elapsed_seconds"] == 100
assert data["progress"]["percent"] == 22
assert data["progress"]["files_transferred"] == 913792
assert data["progress"]["percentage_provisional"] is True
assert data["exit_code"] == 0
PY
if PROXMOX_LXC_TRANSFER_JOB_STATE_DIR="${job_state_dir}" \
  PROXMOX_LXC_TRANSFER_JOB_LOG_DIR="${job_log_dir}" \
    "${ROOT}/cli/rsync/tree.sh" status '../fixture-job' >/dev/null 2>&1; then
  fail 'unsafe managed-transfer job name was accepted'
fi
grep -Fq 'screen -DmS "${session}"' "${ROOT}/cli/rsync/tree.sh" \
  || fail 'managed transfers are not launched through the fixed Screen runner'
ok 'durable job status parses provisional whole-transfer progress and rejects unsafe names'

PATH="${operation_dir}/bin:${PATH}" \
PROXMOX_TEST_ARGUMENTS="${operation_dir}/speed-server.args" \
PROXMOX_LXC_TRANSFER_SELECTION_PATH="${operation_dir}/selection.json" \
  "${ROOT}/cli/network/speed.sh" server
grep -Fxq -- '--one-off' "${operation_dir}/speed-server.args" || fail 'iperf3 server is not one-shot'
grep -Fxq -- '172.29.41.7' "${operation_dir}/speed-server.args" || fail 'iperf3 server is not bound to the selected DATA address'

PATH="${operation_dir}/bin:${PATH}" \
PROXMOX_TEST_ARGUMENTS="${operation_dir}/speed-client.args" \
PROXMOX_LXC_TRANSFER_SELECTION_PATH="${operation_dir}/selection.json" \
  "${ROOT}/cli/network/speed.sh" client 172.29.41.8
grep -Fxq -- '172.29.41.8' "${operation_dir}/speed-client.args" || fail 'iperf3 client omitted the operator-entered peer'
grep -Fxq -- '5201' "${operation_dir}/speed-client.args" || fail 'iperf3 client omitted TCP 5201'
ok 'one-shot selected-address iperf3 server and selected-peer client'
