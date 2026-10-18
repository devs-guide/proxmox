#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '[validate.lxc.transfer][error] %s\n' "$*" >&2; exit 1; }
ok() { printf '[validate.lxc.transfer][ok] %s\n' "$*"; }

RUNNER="${ROOT}/setup/lxc/transfer.sh"
PLAYBOOK="${ROOT}/ansible/proxmox/container/rsync.peer.yml"
UFW_TASKS="${ROOT}/ansible/proxmox/tasks/lxc.transfer.ufw.yml"
SAMBA="${ROOT}/ansible/proxmox/container/samba.file.share.yml"
FIREWALL="${ROOT}/setup/firewall.sh"
SSH_HELPER="${ROOT}/cli/ssh/peer.sh"
RSYNC_HELPER="${ROOT}/cli/rsync/tree.sh"
SPEED_HELPER="${ROOT}/cli/network/speed.sh"

for path in "${RUNNER}" "${PLAYBOOK}" "${UFW_TASKS}" "${SAMBA}" "${FIREWALL}" "${SSH_HELPER}" "${RSYNC_HELPER}" "${SPEED_HELPER}"; do
  [[ -s "${path}" ]] || fail "missing ${path#${ROOT}/}"
done
bash -n "${RUNNER}" "${FIREWALL}" "${SSH_HELPER}" "${RSYNC_HELPER}" "${SPEED_HELPER}" "${ROOT}/setup/lxc/samba.sh"
ok 'shell syntax'

bash "${ROOT}/tests/unit/lxc_transfer_policy_test.sh"
ok 'production parser and topology-neutral fixtures'
bash "${ROOT}/tests/unit/lxc_storage_reconcile_policy_test.sh"
ok 'production post-transfer ACL reconciliation fixture'

grep -Fq 'ListenAddress {{ proxmox_lxc_transfer_effective.local_address }}' "${PLAYBOOK}" || fail 'dedicated sshd is not bound to the selected address'
grep -Fq 'ForceCommand /usr/local/libexec/proxmox-transfer-rrsync-guard' "${PLAYBOOK}" || fail 'forced non-deleting rrsync guard is missing'
grep -Fq '/usr/share/doc/rsync/scripts/rrsync.gz' "${PLAYBOOK}" || fail 'legacy Debian rrsync packaging fallback is missing'
for marker in 'PasswordAuthentication no' 'PermitRootLogin no' 'PermitTTY no' 'AllowTcpForwarding no' 'AllowAgentForwarding no' 'PermitTunnel no'; do
  grep -Fq "${marker}" "${PLAYBOOK}" || fail "missing SSH restriction: ${marker}"
done
grep -Fq 'restrict,from="%s"' "${PLAYBOOK}" || fail 'authorized client keys are not CIDR-restricted'
grep -Fq 'clients.d/{{ proxmox_lxc_transfer_effective.client_id }}.pub' "${PLAYBOOK}" || fail 'per-client revocation registry is missing'
grep -Fq 'Refuse stale or hand-edited transfer selection drift' "${PLAYBOOK}" || fail 'playbook-side operator selection revalidation is missing'
grep -Fq 'Inspect the operator-selected transfer account' "${PLAYBOOK}" || fail 'existing transfer-account discovery is missing'
grep -Fq 'Preserve existing transfer account and require approved storage membership' "${PLAYBOOK}" || fail 'existing transfer accounts are not preserved behind a group-membership gate'
grep -Fq 'Account UID, GID, home, shell, and password are' "${PLAYBOOK}" || fail 'existing account preservation contract is missing'
grep -Fq 'Create the missing restricted transfer account' "${PLAYBOOK}" || fail 'missing transfer-account creation is absent'
grep -Fq 'when: proxmox_lxc_transfer_service_user.rc != 0' "${PLAYBOOK}" || fail 'account creation is not limited to a missing selected user'
grep -Fq 'password: "*"' "${PLAYBOOK}" || fail 'new transfer accounts do not use an impossible password hash'
grep -Fq 'update_password: on_create' "${PLAYBOOK}" || fail 'new-account password policy can rewrite an existing account'
! grep -Fq 'update_password: always' "${PLAYBOOK}" || fail 'transfer feature can still rewrite an existing account password'
! grep -Fq 'password_lock: true' "${PLAYBOOK}" || fail 'new transfer accounts are locked out of the isolated UsePAM=no SSH daemon'
grep -Fq -- '- iperf3' "${PLAYBOOK}" || fail 'iperf3 is not installed by the transfer feature'
grep -Fq -- '- screen' "${PLAYBOOK}" || fail 'GNU Screen is not installed for managed transfer jobs'
grep -Fq 'Keep the distro iperf3 daemon disabled for on-demand testing' "${PLAYBOOK}" || fail 'persistent iperf3 daemon is not disabled'
ok 'rsync-only SSH and account-preservation policy'

grep -Fq 'Allow rsync SSH ingress from the complete selected DATA-Link CIDR' "${UFW_TASKS}" || fail 'LAN-wide ingress task is missing'
grep -Fq 'Allow rsync SSH egress across the complete selected DATA-Link CIDR' "${UFW_TASKS}" || fail 'LAN-wide egress task is missing'
grep -Fq 'proxmox_lxc_transfer_ufw_allow_cidr' "${UFW_TASKS}" || fail 'UFW policy does not consume the selected CIDR'
grep -Fq 'Allow on-demand iperf3 ingress from the complete selected DATA-Link CIDR' "${UFW_TASKS}" || fail 'LAN-wide iperf3 ingress task is missing'
grep -Fq 'Allow on-demand iperf3 egress across the complete selected DATA-Link CIDR' "${UFW_TASKS}" || fail 'LAN-wide iperf3 egress task is missing'
grep -Fq 'proxmox-transfer-iperf-in' "${UFW_TASKS}" || fail 'managed iperf3 ingress rule is missing'
grep -Fq 'proxmox-transfer-iperf-out' "${UFW_TASKS}" || fail 'managed iperf3 egress rule is missing'
[[ "$(grep -Fc -- '- "on"' "${UFW_TASKS}")" -eq 4 ]] || fail 'UFW interface tokens are not all quoted against YAML boolean coercion'
! grep -Eq -- '^[[:space:]]*-[[:space:]]+on[[:space:]]*$' "${UFW_TASKS}" || fail 'an unquoted UFW interface token can become Boolean True'
! grep -Eq '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32' "${UFW_TASKS}" || fail 'peer-specific /32 exists in UFW policy'
grep -Fq 'PROXMOX_FIREWALL_ENABLE_LXC_TRANSFER' "${FIREWALL}" || fail 'Proxmox LXC boundary opt-in is missing'
grep -Fq 'for transfer_port in 22 5201' "${FIREWALL}" || fail 'Proxmox transfer boundary does not manage TCP 22 and TCP 5201 together'
grep -Fq -- '--iface "${DATA_SLOT}" --source "${data_network}" --proto tcp --dport "${transfer_port}"' "${FIREWALL}" || fail 'Proxmox transfer rules are not interface/CIDR specific'
grep -Fq 'On-demand DATA-Link iperf3 tcp/5201' "${FIREWALL}" || fail 'feature-owned Proxmox TCP 5201 rule is missing'
grep -Fq 'pvesh delete "/nodes/${node}/lxc/${CTID}/firewall/rules/${position}"' "${FIREWALL}" || fail 'feature-owned Proxmox transfer-rule removal is missing'
ok 'container and Proxmox full-CIDR firewall boundaries'

grep -Fq -- '--one-off --bind "${LOCAL_ADDRESS}" --port "${IPERF_PORT}"' "${SPEED_HELPER}" || fail 'iperf3 server is not one-shot and DATA-address-bound'
grep -Fq -- '--parallel "${IPERF_STREAMS}"' "${SPEED_HELPER}" || fail 'iperf3 client does not expose the fixed multi-stream test'
grep -Fq 'proxmox-transfer-check' "${SSH_HELPER}" || fail 'SSH client pairing check is missing'
grep -Fq 'proxmox-transfer-ssh-ok' "${PLAYBOOK}" || fail 'SSH server pairing check is missing'
for forbidden in --delete --delete-before --delete-after --delete-during --delete-excluded --remove-source-files; do
  ! grep -Fq -- "${forbidden}" "${RSYNC_HELPER}" || fail "rsync helper contains destructive option ${forbidden}"
done
! grep -Fq -- '--protect-args' "${RSYNC_HELPER}" || fail 'rsync helper requests server option -s, which distro rrsync disables'
grep -Fq 'verify-push' "${RSYNC_HELPER}" || fail 'optional push verification is missing'
grep -Fq 'verify-pull' "${RSYNC_HELPER}" || fail 'optional pull verification is missing'
grep -Fq -- '--dry-run --checksum --itemize-changes --stats' "${RSYNC_HELPER}" || fail 'verification is not a checksum dry run'
grep -Fq 'argument.startswith("--delet")' "${PLAYBOOK}" || fail 'forced-command guard does not reject rsync deletion options and abbreviations'
grep -Fq 'argument.startswith("--remove-s")' "${PLAYBOOK}" || fail 'forced-command guard does not reject source-file removal and abbreviations'
ok 'on-demand bandwidth test and non-deleting copy policy'

grep -Fq 'proxmox_lxc_transfer_runtime_path' "${SAMBA}" || fail 'Samba does not discover active transfer runtime facts'
grep -Fq 'Restore the active LAN-wide restricted transfer policy after UFW reset' "${SAMBA}" || fail 'Samba UFW reset does not restore transfer rules'
grep -Fq 'not (proxmox_lxc_transfer_preserved.enabled | bool)' "${SAMBA}" || fail 'Samba can still purge the active transfer SSH package'
grep -Fq 'proxmox/tasks/lxc.transfer.ufw.yml' "${ROOT}/setup/lxc/samba.sh" || fail 'Samba runner omits its shared UFW dependency'
ok 'Samba coexistence policy'

for artifact in setup/lxc/transfer.sh docs/setup/lxc/transfer.md docs/release/0.0.8.md; do
  grep -Fq "${artifact}|${artifact}|" "${ROOT}/actions/pages.features.txt" || fail "Pages manifest omits ${artifact}"
done
grep -Fq 'SETUP_LXC_TRANSFER_RUNNER="setup/lxc/transfer.sh"' "${ROOT}/actions/www.pages.sh" || fail 'Pages Ansible graph omits the transfer runner'
ok 'Pages dependency graph declarations'

if command -v ruby >/dev/null 2>&1; then
  ruby -e 'require "yaml"; ARGV.each { |p| YAML.load_file(p) }' "${PLAYBOOK}" "${UFW_TASKS}" "${SAMBA}" "${ROOT}/ansible/group_vars/proxmox.yml"
  ok 'YAML parse'
fi
if command -v ansible-playbook >/dev/null 2>&1; then
  ansible-playbook --syntax-check -i localhost, "${PLAYBOOK}" >/dev/null
  ansible-playbook --syntax-check -i localhost, "${SAMBA}" >/dev/null
  ok 'Ansible syntax'
fi

git -C "${ROOT}" diff --check
ok 'diff hygiene'
