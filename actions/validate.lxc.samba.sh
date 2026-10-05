#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '[validate.lxc.samba][error] %s\n' "$*" >&2; exit 1; }
ok() { printf '[validate.lxc.samba][ok] %s\n' "$*"; }

SHELL_FILES=(
  "${ROOT}/setup/vlan.sh"
  "${ROOT}/setup/network-link.sh"
  "${ROOT}/setup/network.sh"
  "${ROOT}/setup/firewall.sh"
  "${ROOT}/setup/lxc/debian.sh"
  "${ROOT}/setup/lxc/samba.sh"
  "${ROOT}/setup/lxc/storage.sh"
  "${ROOT}/setup/lxc/egress.sh"
)
for path in "${SHELL_FILES[@]}"; do [[ -f "${path}" ]] || fail "missing ${path#${ROOT}/}"; done
bash -n "${SHELL_FILES[@]}"
ok 'shell syntax'

HARDWARE="${ROOT}/ansible/proxmox/helper/hardware.yml"
VLAN="${ROOT}/ansible/proxmox/vlan.yml"
VLAN_TASKS="${ROOT}/ansible/proxmox/tasks/data-link.candidate.yml"
VLAN_IFRELOAD_TASKS="${ROOT}/ansible/proxmox/tasks/data-link.ifreload.validate.yml"
VLAN_TEMPLATE="${ROOT}/ansible/proxmox/templates/data-link.interfaces.j2"
NETWORK="${ROOT}/setup/network.sh"
UPDATE="${ROOT}/ansible/proxmox/network.update.yml"
VERIFY="${ROOT}/ansible/proxmox/network.verify.yml"
LXC_NIC_HELPER="${ROOT}/ansible/proxmox/helper/network.lxc_nic.py"
SAMBA="${ROOT}/ansible/proxmox/container/samba.file.share.yml"
GROUP_VARS="${ROOT}/ansible/group_vars/proxmox.yml"
PACKAGES="${ROOT}/ansible/debian/packages.yml"

grep -q 'supported_speed_mbps' "${HARDWARE}" || fail 'supported NIC speed is not persisted'
grep -q 'permanent_mac' "${HARDWARE}" || fail 'permanent NIC MAC is not persisted'
grep -q "reject('match', '\^veth')" "${HARDWARE}" || fail 'veth interfaces are not excluded'
grep -q "reject('match', '\^fw')" "${HARDWARE}" || fail 'Proxmox firewall interfaces are not excluded'
grep -q "link_mode.*untagged" "${VLAN}" || fail 'untagged bridge mode is missing'
grep -q 'expected_mac' "${VLAN}" || fail 'MAC drift assertion is missing'
grep -q 'probe.selected.data.nic' "${ROOT}/setup/vlan.sh" || fail 'temporary link probe is missing'
grep -q 'ensure.data.link.ready' "${ROOT}/setup/vlan.sh" || fail 'VLAN apply does not delegate DATA-Link activation'
grep -q 'no physical carrier was detected' "${ROOT}/setup/network-link.sh" || fail 'physical carrier error is not surfaced'
grep -q 'proxmox_vlan_fatal_parser_warning_pattern' "${VLAN}" || fail 'zero-exit parser warnings are not fatal'
grep -q 'Parse complete DATA-Link candidate interface list' "${VLAN}" || fail 'candidate config is not parsed before mutation'
grep -q 'Search rendered candidate for a literal backslash-n escape' "${VLAN_TASKS}" || fail 'literal newline escapes are not rejected'
grep -q 'bridge-ports' "${VLAN_TEMPLATE}" || fail 'canonical DATA-Link template is missing bridge membership'
grep -q 'Collect selected physical NIC IPv4 methods by interface tokens' "${VLAN_TASKS}" || fail 'DATA-Link candidate does not use the canonical token parser'
grep -q 'proxmox_vlan_data_nic_policy_valid' "${VLAN_TASKS}" || fail 'DATA-Link candidate does not reject non-manual IPv4 declarations'
grep -q 'proxmox/tasks/data-link.candidate.yml' "${ROOT}/setup/vlan.sh" || fail 'candidate task is not a runner support dependency'
grep -q 'proxmox/tasks/data-link.ifreload.validate.yml' "${ROOT}/setup/vlan.sh" || fail 'ifreload validation task is not a runner support dependency'
grep -q 'proxmox/templates/data-link.interfaces.j2' "${ROOT}/setup/vlan.sh" || fail 'candidate template is not a runner support dependency'
grep -q 'Run DATA-Link ifreload parser validation without mutation' "${VLAN_IFRELOAD_TASKS}" || fail 'shared syntax validation is missing'
grep -q 'Run DATA-Link ifreload reload-plan validation without mutation' "${VLAN_IFRELOAD_TASKS}" || fail 'shared reload-plan validation is missing'
[[ "$(grep -Ec '^[[:space:]]+- -n$' "${VLAN_IFRELOAD_TASKS}")" -eq 2 ]] || fail 'both ifreload validations must use no-action mode'
! grep -q 'ip link set dev.*master' "${VLAN}" || fail 'forced runtime bridge attachment remains'
ok 'physical NIC discovery and identity contract'

grep -q 'add_static_data_role_no_gateway' "${NETWORK}" || fail 'static no-gateway data role is missing'
grep -q 'firewall=1,ip=${PROXMOX_NETWORK_UPDATE_DATA_IPV4_CIDR}' "${NETWORK}" || fail 'data NIC is not serialized as static/firewalled'
! grep -q 'selected_lxc_highspeed_only' "${NETWORK}" || fail 'destructive net0 replacement path remains'
[[ -f "${LXC_NIC_HELPER}" ]] || fail 'canonical LXC NIC parser is missing'
grep -q 'unsafe_data_route' "${LXC_NIC_HELPER}" || fail 'gateway/DHCP rejection is missing'
grep -q 'GENERATED_KEYS = {"type", "hwaddr"}' "${LXC_NIC_HELPER}" || fail 'Proxmox-generated LXC fields are not normalized'
grep -q 'network.lxc_nic.py' "${UPDATE}" || fail 'network update does not use the canonical LXC NIC parser'
grep -q 'network.lxc_nic.py' "${VERIFY}" || fail 'network verification does not use the canonical LXC NIC parser'
grep -q 'refuse_live_slot_overwrite' "${UPDATE}" || fail 'live slot overwrite protection is missing'
grep -q 'rollback.network.update.plan' "${NETWORK}" || fail 'guest NIC rollback is missing'
grep -q 'network.transaction.tsv' "${NETWORK}" || fail 'guest NIC transaction journal is missing'
grep -q 'detect.pending.network.recovery' "${NETWORK}" || fail 'failed update recovery path is missing'
grep -q 'probe.data.ip.conflict' "${NETWORK}" || fail 'duplicate static-address probe is missing'
grep -q 'normalize.ipv4.interface.cidr' "${NETWORK}" || fail 'bare IPv4 normalization is missing'
grep -q 'network.update.status.yml' "${NETWORK}" || fail 'transactional update status is missing'
grep -q '__WOULD_CHANGE__' "${UPDATE}" || fail 'check-mode would-change reporting is missing'
grep -Fxq '      - iputils-arping' "${PACKAGES}" || fail 'arping is not in the networking baseline'
grep -q 'ensure.lxc.runtime.data.role' "${NETWORK}" || fail 'running-container NIC activation verification is missing'
grep -q 'PROXMOX_NETWORK_ALLOW_LXC_RESTART' "${NETWORK}" || fail 'operator-controlled restart gate is missing'
! grep -Fq 'NR > 1 ? NR - 1 : 0' "${NETWORK}" || fail 'non-portable awk row-count expression remains'
grep -Fq 'network.snapshot.status.yml' "${NETWORK}" || fail 'network snapshot status is missing'
grep -Fq 'network.snapshot.ready' "${NETWORK}" || fail 'network update-ready marker is missing'
grep -Fq 'latest-ready' "${NETWORK}" || fail 'update does not resolve the latest ready snapshot'
grep -Fq 'require.live.update.topology' "${NETWORK}" || fail 'live topology revalidation is missing'
grep -Fq 'MIN_DATA_SPEED_MBPS' "${ROOT}/setup/vlan.sh" || fail 'gigabit data-NIC floor is missing'
grep -Fq 'vlan.pending.yml' "${ROOT}/setup/vlan.sh" || fail 'pending DATA-Link selection state is missing'
grep -Fq 'vlan.applied.yml' "${ROOT}/setup/vlan.sh" || fail 'applied DATA-Link selection state is missing'
grep -Fq 'vlan.applied.yml' "${NETWORK}" || fail 'guest handoff does not require applied DATA-Link state'
ok 'role-based LXC network contract'

bash "${ROOT}/tests/unit/network_snapshot_policy_test.sh"
bash "${ROOT}/tests/unit/network_lxc_nic_policy_test.sh"
bash "${ROOT}/tests/unit/network_update_playbook_policy_test.sh"
bash "${ROOT}/tests/unit/network_update_transaction_policy_test.sh"
ok 'production DATA-Link address, semantic parser, apply/verify, and rollback fixtures'

bash "${ROOT}/tests/unit/samba_credential_policy_test.sh"
ok 'Samba hostname/custom credential and secret-cleanup fixtures'

grep -q 'force_user: "smb-ingest"' "${GROUP_VARS}" || fail 'non-root Samba service user is not the default'
! grep -q 'force_user: "root"' "${SAMBA}" || fail 'Samba root forcing remains'
grep -q '_RO]' "${SAMBA}" && grep -q '_RW]' "${SAMBA}" || fail 'dual Samba shares are missing'
grep -q 'Prove guest writes are rejected' "${SAMBA}" || fail 'guest read-only write probe is missing'
grep -q 'Prove authenticated create rename and delete' "${SAMBA}" || fail 'authenticated write lifecycle probe is missing'
grep -q 'default deny outgoing' "${SAMBA}" || fail 'default-deny egress is missing'
grep -q 'Require SMB listener to stay on loopback and the selected data role' "${SAMBA}" || fail 'SMB listener binding verification is missing'
grep -q 'ssh.socket' "${SAMBA}" || fail 'SSH socket masking is missing'
grep -q 'Remove the SSH server package' "${SAMBA}" || fail 'SSH server removal is missing'
grep -q 'Lock temporary interactive accounts' "${SAMBA}" || fail 'temporary account locking is missing'
grep -q 'Stop and mask legacy NetBIOS discovery' "${SAMBA}" || fail 'NetBIOS daemon hardening is missing'
grep -q 'credential_mode.*hostname' "${GROUP_VARS}" || fail 'hostname credential mode is not the default'
grep -q 'remove.samba.secret.file' "${ROOT}/setup/lxc/samba.sh" || fail 'temporary Samba secret cleanup is missing'
grep -q 'custom username and password' "${ROOT}/setup/lxc/samba.sh" || fail 'custom Samba credential selection is missing'
grep -q 'setup/lxc/storage.sh' "${SAMBA}" || fail 'mapped host ACL remediation is missing'
grep -q 'pct exec.*setpriv' "${ROOT}/setup/lxc/storage.sh" || fail 'mapped identity container verification is missing'
grep -q 'remove_managed_rules' "${ROOT}/setup/lxc/egress.sh" || fail 'egress approval reconciliation is missing'
grep -q 'preflight|apply|revoke' "${ROOT}/setup/lxc/egress.sh" || fail 'egress revoke mode is missing'
grep -q '/lxc/${CTID}/firewall/rules' "${ROOT}/setup/firewall.sh" || fail 'Proxmox LXC boundary rule is missing'
grep -q -- '--iface "${DATA_SLOT}"' "${ROOT}/setup/firewall.sh" || fail 'LXC SMB rule is not bound to the discovered PVE NIC slot'
grep -q '^set -Eeuo pipefail$' "${ROOT}/setup/firewall.sh" || fail 'firewall ERR rollback is not inherited by main'
grep -q 'CLUSTER_BACKUP_PATH=' "${ROOT}/setup/firewall.sh" || fail 'cluster firewall rollback backup is missing'
grep -q 'pvesh set /cluster/firewall/options --enable 1 --policy_in DROP --policy_out ACCEPT' "${ROOT}/setup/firewall.sh" \
  || fail 'cluster firewall does not own host default policies'
! grep -q '"/nodes/${node}/firewall/options".*policy_in' "${ROOT}/setup/firewall.sh" \
  || fail 'unsupported node-level firewall policy options remain'
grep -q -- '--dhcp "${ct_dhcp_required}"' "${ROOT}/setup/firewall.sh" || fail 'LXC DHCP preservation is missing'
ok 'Samba, storage, and hardening contract'

for published in setup/network-link.sh setup/firewall.sh setup/lxc/storage.sh setup/lxc/egress.sh docs/setup/lxc/ingest.md docs/setup/lxc/networking.md docs/development/feature-authoring.md; do
  grep -q "^${published}|${published}|feature$" "${ROOT}/actions/pages.features.txt" \
    || fail "Pages manifest omits ${published}"
done
ok 'Pages feature manifest'

if command -v ansible-playbook >/dev/null 2>&1; then
  for playbook in \
    ansible/proxmox/helper/hardware.yml \
    ansible/proxmox/helper/network.preflight.export.yml \
    ansible/proxmox/vlan.yml \
    ansible/proxmox/network.update.yml \
    ansible/proxmox/network.verify.yml \
    ansible/proxmox/container/samba.file.share.yml; do
    ansible-playbook --syntax-check -i localhost, "${ROOT}/${playbook}" >/dev/null
  done
  ok 'Ansible syntax'
fi
