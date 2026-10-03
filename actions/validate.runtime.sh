#!/usr/bin/env bash
set -euo pipefail

# Lightweight runtime sanity checklist for proxmox 9.1 (manual/offline friendly).
# Local contract check only: validates local repo artifacts and runtime-facing checks.
# This is not a publish/drift validator and does not fetch from the live Pages URL.
# Live Pages publish validation remains in actions/validate.pages.sh (remote or local modes).
#
# Steps:
# 1) Confirm key files exist locally.
# 2) Show effective package groups with host_platform_family=proxmox.
# 3) Optional: run ansible install.packages.yml in check mode (if host is suitable).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

files=(
  "AGENTS.md"
  "docs/development/feature-authoring.md"
  "bootstrap/release.9.1.sh"
  "bootstrap/release.6.4.sh"
  "bootstrap/release.common.sh"
  "bootstrap/ansible.runtime.sh"
  "tests/unit/ansible_runtime_policy_test.sh"
  "tests/unit/debian_lxc_template_policy_test.sh"
  "tests/unit/network_snapshot_policy_test.sh"
  "tests/unit/data_link_policy_test.sh"
  "tests/unit/data_link_ifreload_policy_test.sh"
  "tests/unit/ansible_regex_presence_policy_test.sh"
  "actions/validate.release.sh"
  "setup/vlan.sh"
  "setup/network-link.sh"
  "setup/network.sh"
  "setup/cli.codex.sh"
  "setup/lxc/debian.sh"
"setup/lxc/samba.sh"
"setup/lxc/common.sh"
"setup/lxc/network.sh"
  "setup/lxc/codex.sh"
  "setup/lxc/users.sh"
  "ansible/release/6.4/install.playbooks.txt"
  "ansible/release/9.1/install.playbooks.txt"
  "ansible/debian/ansible.venv.yml"
  "ansible/debian/install.packages.yml"
  "ansible/debian/cli.codex.yml"
  "ansible/debian/netboot.yml"
  "ansible/debian/packages.yml"
  "ansible/debian/ssh.yml"
  "ansible/debian/sources.trixie.yml"
  "ansible/group_vars/proxmox.yml"
  "ansible/proxmox/helper/hardware.yml"
  "ansible/proxmox/helper/network.preflight.export.yml"
  "ansible/proxmox/network.update.yml"
  "ansible/proxmox/network.verify.yml"
  "ansible/proxmox/vlan.yml"
  "ansible/proxmox/tasks/data-link.candidate.yml"
  "ansible/proxmox/tasks/data-link.ifreload.validate.yml"
  "ansible/proxmox/templates/data-link.interfaces.j2"
  "ansible/proxmox/container/bootstrap/debian.create.yml"
  "ansible/proxmox/common.yml"
  "ansible/proxmox/container/debian.lxc.yml"
  "ansible/proxmox/container/debian.yml"
  "ansible/proxmox/container/debian.base.yml"
  "ansible/proxmox/container/node.yml"
  "ansible/proxmox/container/codex.yml"
  "ansible/proxmox/container/samba.file.share.yml"
  "ansible/proxmox/container/network.access.yml"
  "ansible/group_vars/trixie.yml"
  "ansible/release/9.1/group_vars/all.yml"
  "ansible/proxmox/container/common.yml"
  "ansible/proxmox/container/users.yml"
)

echo "[validate.runtime] checking for required files..."
missing=0
for f in "${files[@]}"; do
  if [[ ! -f "${ROOT}/${f}" ]]; then
    echo "[missing] ${f}"
    missing=1
  else
    echo "[ok] ${f}"
  fi
done
if [[ "${missing}" -ne 0 ]]; then
  echo "[validate.runtime] missing files detected; aborting."
  exit 1
fi

echo "[validate.runtime] checking 9.1 playlist runtime authority..."
if grep -qx 'debian/ansible.venv.yml' "${ROOT}/ansible/release/9.1/install.playbooks.txt"; then
  echo "[validate.runtime][error] 9.1 playlist still references debian/ansible.venv.yml"
  exit 1
fi
echo "[validate.runtime][ok] 9.1 playlist delegates runtime bootstrap to release.common.sh"

echo "[validate.runtime] checking 9.1 bootstrap apt source cleanup..."
if ! grep -q 'disable.enterprise.sources()' "${ROOT}/bootstrap/release.9.1.sh"; then
  echo "[validate.runtime][error] bootstrap/release.9.1.sh must define disable.enterprise.sources()"
  exit 1
fi
if ! grep -q 'Disabling Proxmox enterprise apt sources before bootstrap update' "${ROOT}/bootstrap/release.9.1.sh"; then
  echo "[validate.runtime][error] bootstrap/release.9.1.sh must log enterprise source cleanup before apt update"
  exit 1
fi
if ! grep -q "enterprise\\\\.proxmox\\\\.com/debian/(pve|ceph)" "${ROOT}/bootstrap/release.9.1.sh"; then
  echo "[validate.runtime][error] bootstrap/release.9.1.sh must clean enterprise Proxmox and Ceph source entries by content"
  exit 1
fi
if ! grep -q 'ceph.release.gpg' "${ROOT}/bootstrap/release.9.1.sh"; then
  echo "[validate.runtime][error] bootstrap/release.9.1.sh must drop legacy Ceph enterprise key material"
  exit 1
fi
if ! grep -q 'disable.enterprise.sources' "${ROOT}/bootstrap/release.9.1.sh"; then
  echo "[validate.runtime][error] bootstrap/release.9.1.sh must call disable.enterprise.sources before bootstrap apt update"
  exit 1
fi
if ! grep -q 'Find enterprise deb822/list apt source files for cleanup' "${ROOT}/ansible/release/9.1/enterprise.yml"; then
  echo "[validate.runtime][error] ansible/release/9.1/enterprise.yml must locate enterprise deb822/list source files for cleanup"
  exit 1
fi
if ! grep -q 'Remove enterprise deb822/list apt source files when using no-subscription' "${ROOT}/ansible/release/9.1/enterprise.yml"; then
  echo "[validate.runtime][error] ansible/release/9.1/enterprise.yml must remove enterprise deb822/list source files in no-subscription mode"
  exit 1
fi
if ! grep -q 'ceph.release.gpg' "${ROOT}/ansible/release/9.1/enterprise.yml"; then
  echo "[validate.runtime][error] ansible/release/9.1/enterprise.yml must remove legacy Ceph enterprise key material"
  exit 1
fi
echo "[validate.runtime][ok] 9.1 bootstrap cleans enterprise PVE/Ceph sources before apt update"

echo "[validate.runtime] checking Proxmox feature runner contract..."
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh does not define FEATURE_PLAYBOOKS array"
  exit 1
fi
if ! grep -q '"proxmox/helper/hardware.yml"' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh FEATURE_PLAYBOOKS is missing proxmox/helper/hardware.yml"
  exit 1
fi
if ! grep -q '"proxmox/vlan.yml"' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh FEATURE_PLAYBOOKS is missing proxmox/vlan.yml"
  exit 1
fi
if ! grep -q '/dev/tty' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh is missing TTY input handling (/dev/tty)"
  exit 1
fi
if ! grep -Fq "row=\"\${row//\\\\t/\$'\t'}\"" "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh does not normalize literal \\t rows from hardware.nics.tsv"
  exit 1
fi
if ! grep -q 'hardware.nics.tsv' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh is missing hardware.nics.tsv usage"
  exit 1
fi
if ! grep -q 'vlan.selection.yml' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh is missing vlan.selection.yml usage"
  exit 1
fi
if ! grep -q 'proxmox_feature_defaults.vlan.enabled=true' "${ROOT}/setup/vlan.sh"; then
  true
fi
if grep -q 'proxmox_feature_defaults\.vlan\.' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh must not use dotted nested Ansible extra-vars for proxmox_feature_defaults.vlan.*"
  exit 1
fi
if ! grep -q 'VLAN_EXTRA_VARS_PATH=' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh is missing VLAN_EXTRA_VARS_PATH for generated YAML extra-vars"
  exit 1
fi
if ! grep -q 'write.vlan.extra.vars.file()' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh is missing write.vlan.extra.vars.file()"
  exit 1
fi
if ! grep -q -- '-e "@${VLAN_EXTRA_VARS_PATH}"' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh must pass generated YAML extra-vars with -e @file"
  exit 1
fi
if ! grep -q 'Selectable VM/LXC data NICs:' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh is missing the readable VLAN NIC selection UI"
  exit 1
fi
echo "[validate.runtime][ok] setup/vlan.sh uses generated YAML extra-vars and exposes the readable NIC UI"

echo "[validate.runtime] checking physical DATA-Link runner contract..."
for marker in \
  'preflight|up' \
  'administratively down. Bring up this DATA-Link now?' \
  'no physical carrier was detected' \
  'network-link.ready.yml' \
  'PROXMOX_NETWORK_LINK_MIN_SPEED_MBPS'; do
  if ! grep -Fq -- "${marker}" "${ROOT}/setup/network-link.sh"; then
    echo "[validate.runtime][error] setup/network-link.sh is missing marker: ${marker}"
    exit 1
  fi
done
if ! grep -Fq 'ensure.data.link.ready()' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh does not delegate physical activation to the DATA-Link runner"
  exit 1
fi
echo "[validate.runtime][ok] DATA-Link activation distinguishes admin state from physical carrier"

echo "[validate.runtime] checking Proxmox network runner contract..."
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/network.sh"; then
  echo "[validate.runtime][error] setup/network.sh does not define FEATURE_PLAYBOOKS array"
  exit 1
fi
if ! grep -q '"proxmox/helper/network.preflight.export.yml"' "${ROOT}/setup/network.sh"; then
  echo "[validate.runtime][error] setup/network.sh FEATURE_PLAYBOOKS is missing proxmox/helper/network.preflight.export.yml"
  exit 1
fi
if ! grep -q '"proxmox/network.update.yml"' "${ROOT}/setup/network.sh"; then
  echo "[validate.runtime][error] setup/network.sh FEATURE_PLAYBOOKS is missing proxmox/network.update.yml"
  exit 1
fi
if ! grep -q '"proxmox/network.verify.yml"' "${ROOT}/setup/network.sh"; then
  echo "[validate.runtime][error] setup/network.sh FEATURE_PLAYBOOKS is missing proxmox/network.verify.yml"
  exit 1
fi
if ! grep -q '/etc/ansible/proxmox/facts' "${ROOT}/setup/network.sh"; then
  echo "[validate.runtime][error] setup/network.sh must use /etc/ansible/proxmox/facts"
  exit 1
fi
if ! grep -q 'update: config network' "${ROOT}/setup/network.sh"; then
  echo "[validate.runtime][error] setup/network.sh must present update stage selection in interactive mode"
  exit 1
fi
if ! grep -q 'network.intent.yml' "${ROOT}/setup/network.sh"; then
  echo "[validate.runtime][error] setup/network.sh must persist network.intent.yml"
  exit 1
fi
if ! grep -q 'network.plan.tsv' "${ROOT}/setup/network.sh"; then
  echo "[validate.runtime][error] setup/network.sh must persist network.plan.tsv"
  exit 1
fi
echo "[validate.runtime][ok] setup/network.sh exposes preflight/export/update/verify contract"

if grep -Fq 'NR > 1 ? NR - 1 : 0' "${ROOT}/setup/network.sh"; then
  echo "[validate.runtime][error] setup/network.sh retains the non-portable awk row-count expression"
  exit 1
fi
for marker in \
  'tsv.data.row.count()' \
  'network.snapshot.status.yml' \
  'network.snapshot.ready' \
  'latest-ready' \
  'require.live.update.topology()' \
  'PROXMOX_NETWORK_MIN_DATA_SPEED_MBPS' \
  'Data CIDR ${EXPECTED_DATA_CIDR} overlaps management CIDR'; do
  if ! grep -Fq -- "${marker}" "${ROOT}/setup/network.sh"; then
    echo "[validate.runtime][error] setup/network.sh is missing fail-closed marker: ${marker}"
    exit 1
  fi
done
for marker in \
  'PROXMOX_VLAN_MIN_DATA_SPEED_MBPS' \
  'nic.meets.minimum.speed()' \
  'data LAN policy requires at least'; do
  if ! grep -Fq -- "${marker}" "${ROOT}/setup/vlan.sh"; then
    echo "[validate.runtime][error] setup/vlan.sh is missing dynamic gigabit data-NIC marker: ${marker}"
    exit 1
  fi
done
echo "[validate.runtime][ok] network runners fail closed on incomplete or sub-gigabit data topology"
"${ROOT}/tests/unit/data_link_policy_test.sh"
"${ROOT}/tests/unit/data_link_ifreload_policy_test.sh"
"${ROOT}/tests/unit/ansible_regex_presence_policy_test.sh"

echo "[validate.runtime] checking Proxmox Node/Codex runner contract..."
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/cli.codex.sh"; then
  echo "[validate.runtime][error] setup/cli.codex.sh does not define FEATURE_PLAYBOOKS array"
  exit 1
fi
if ! grep -q '"debian/node.yml"' "${ROOT}/setup/cli.codex.sh"; then
  echo "[validate.runtime][error] setup/cli.codex.sh FEATURE_PLAYBOOKS is missing debian/node.yml"
  exit 1
fi
if ! grep -q '"debian/cli.codex.yml"' "${ROOT}/setup/cli.codex.sh"; then
  echo "[validate.runtime][error] setup/cli.codex.sh FEATURE_PLAYBOOKS is missing debian/cli.codex.yml"
  exit 1
fi
if ! grep -q 'CLI_CODEX_EXTRA_VARS_PATH=' "${ROOT}/setup/cli.codex.sh"; then
  echo "[validate.runtime][error] setup/cli.codex.sh is missing CLI_CODEX_EXTRA_VARS_PATH"
  exit 1
fi
if ! grep -q 'write.cli.codex.extra.vars.file()' "${ROOT}/setup/cli.codex.sh"; then
  echo "[validate.runtime][error] setup/cli.codex.sh is missing write.cli.codex.extra.vars.file()"
  exit 1
fi
if ! grep -q -- '-e "@${CLI_CODEX_EXTRA_VARS_PATH}"' "${ROOT}/setup/cli.codex.sh"; then
  echo "[validate.runtime][error] setup/cli.codex.sh must pass generated YAML extra-vars with -e @file"
  exit 1
fi
if ! grep -q 'ensure.container.ansible' "${ROOT}/setup/cli.codex.sh"; then
  echo "[validate.runtime][error] setup/cli.codex.sh must use the lightweight container-style Ansible bootstrap helper"
  exit 1
fi
if grep -q 'ensure.managed.ansible' "${ROOT}/setup/cli.codex.sh"; then
  echo "[validate.runtime][error] setup/cli.codex.sh must not require the full managed-target bootstrap path"
  exit 1
fi
if ! grep -q 'setup.cli.codex.sh' "${ROOT}/setup/cli.codex.sh"; then
  echo "[validate.runtime][error] setup/cli.codex.sh must advertise its published setup.cli.codex.sh URL"
  exit 1
fi
echo "[validate.runtime][ok] setup/cli.codex.sh exposes the minimal CLI/Codex runner contract"

echo "[validate.runtime] checking Proxmox LXC Codex runner contract..."
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh does not define FEATURE_PLAYBOOKS array"
  exit 1
fi
if ! grep -q '"proxmox/container/node.yml"' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh FEATURE_PLAYBOOKS is missing proxmox/container/node.yml"
  exit 1
fi
if ! grep -q '"proxmox/container/codex.yml"' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh FEATURE_PLAYBOOKS is missing proxmox/container/codex.yml"
  exit 1
fi
if ! grep -q 'FEATURE_SUPPORT_FILES=(' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh does not define FEATURE_SUPPORT_FILES array"
  exit 1
fi
if ! grep -q '"debian/node.yml"' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh FEATURE_SUPPORT_FILES is missing debian/node.yml"
  exit 1
fi
if ! grep -q '"debian/cli.codex.yml"' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh FEATURE_SUPPORT_FILES is missing debian/cli.codex.yml"
  exit 1
fi
if ! grep -q '"proxmox/container/common.yml"' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh FEATURE_SUPPORT_FILES is missing proxmox/container/common.yml"
  exit 1
fi
if ! grep -q 'LXC_CODEX_EXTRA_VARS_PATH=' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh is missing LXC_CODEX_EXTRA_VARS_PATH"
  exit 1
fi
if ! grep -q 'write.lxc.codex.extra.vars.file()' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh is missing write.lxc.codex.extra.vars.file()"
  exit 1
fi
if ! grep -q -- '-e "@${LXC_CODEX_EXTRA_VARS_PATH}"' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh must pass generated YAML extra-vars with -e @file"
  exit 1
fi
if ! grep -q 'ensure.container.ansible' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh must use the lightweight container-style Ansible bootstrap helper"
  exit 1
fi
if ! grep -q 'ensure.root.or.sudo.reexec' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh must support sudo re-entry instead of requiring the operator to start as root"
  exit 1
fi
if ! grep -q 'LXC_COMMON_HELPER_NAME="common.sh"' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh must define the shared LXC helper name"
  exit 1
fi
if ! grep -q 'source.lxc.common()' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh must source setup/lxc/common.sh before running feature orchestration"
  exit 1
fi
if ! grep -q 'lxc.common.report.binary.status' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh must report the Codex sandbox helper status via setup/lxc/common.sh"
  exit 1
fi
if grep -q 'ensure.managed.ansible' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh must not require the full managed-target bootstrap path"
  exit 1
fi
if ! grep -q 'require.container.not.host()' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh must refuse host execution by default"
  exit 1
fi
if ! grep -q 'setup/lxc/codex.sh' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh must advertise its published setup/lxc/codex.sh URL"
  exit 1
fi
if ! grep -q 'NODE_INSTALL_SCOPE="${PROXMOX_LXC_CODEX_NODE_INSTALL_SCOPE:-shared}"' "${ROOT}/setup/lxc/codex.sh"; then
  echo "[validate.runtime][error] setup/lxc/codex.sh must default to shared Node install scope for multi-user containers"
  exit 1
fi
if ! grep -q 'import_playbook: ../../debian/node.yml' "${ROOT}/ansible/proxmox/container/node.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/container/node.yml must import ../../debian/node.yml"
  exit 1
fi
if ! grep -q 'import_playbook: ../../debian/cli.codex.yml' "${ROOT}/ansible/proxmox/container/codex.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/container/codex.yml must import ../../debian/cli.codex.yml"
  exit 1
fi
if ! grep -q "lookup('file', playbook_dir ~ '/common.yml')" "${ROOT}/ansible/proxmox/container/codex.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/container/codex.yml must load LXC container defaults from common.yml"
  exit 1
fi
if ! grep -q 'Ensure LXC Codex runtime packages are installed' "${ROOT}/ansible/proxmox/container/codex.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/container/codex.yml must install the LXC Codex runtime package contract before delegating to debian/cli.codex.yml"
  exit 1
fi
if ! grep -q 'Assert LXC Codex runtime binaries are present' "${ROOT}/ansible/proxmox/container/codex.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/container/codex.yml must assert the LXC Codex runtime binary contract"
  exit 1
fi
echo "[validate.runtime][ok] setup/lxc/codex.sh exposes the LXC wrapper entrypoint contract"

echo "[validate.runtime] checking Proxmox LXC users runner contract..."
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh does not define FEATURE_PLAYBOOKS array"
  exit 1
fi
if ! grep -q '"proxmox/container/users.yml"' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh FEATURE_PLAYBOOKS is missing proxmox/container/users.yml"
  exit 1
fi
if ! grep -q 'FEATURE_SUPPORT_FILES=(' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh does not define FEATURE_SUPPORT_FILES array"
  exit 1
fi
if ! grep -q '"debian/users.yml"' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh FEATURE_SUPPORT_FILES is missing debian/users.yml"
  exit 1
fi
if ! grep -q '"proxmox/container/common.yml"' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh FEATURE_SUPPORT_FILES is missing proxmox/container/common.yml"
  exit 1
fi
if ! grep -q 'LXC_USERS_EXTRA_VARS_PATH=' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh is missing LXC_USERS_EXTRA_VARS_PATH"
  exit 1
fi
if ! grep -q 'proxmox_users_skip_container_safety_checks: true' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh must force container-safe users flow"
  exit 1
fi
if ! grep -q 'write.lxc.users.extra.vars.file()' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh is missing write.lxc.users.extra.vars.file()"
  exit 1
fi
if ! grep -q -- '-e "@${LXC_USERS_EXTRA_VARS_PATH}"' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh must pass generated YAML extra-vars with -e @file"
  exit 1
fi
if ! grep -q 'ensure.container.ansible' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh must use the lightweight container-style Ansible bootstrap helper"
  exit 1
fi
if ! grep -q 'ensure.root.or.sudo.reexec' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh must support sudo re-entry instead of requiring the operator to start as root"
  exit 1
fi
if grep -q 'ensure.managed.ansible' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh must not require the full managed-target bootstrap path"
  exit 1
fi
if ! grep -q 'require.container.not.host()' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh must refuse host execution by default"
  exit 1
fi
if ! grep -q 'setup/lxc/users.sh' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh must advertise its published setup/lxc/users.sh URL"
  exit 1
fi
if ! grep -q 'PROXMOX_LXC_COMMON_BASELINE_USERS=.*root app agent' "${ROOT}/setup/lxc/common.sh"; then
  echo "[validate.runtime][error] setup/lxc/common.sh must define the LXC common baseline as root app agent"
  exit 1
fi
if ! grep -q 'PROXMOX_LXC_CODEX_SANDBOX_PACKAGE=.*bubblewrap' "${ROOT}/setup/lxc/common.sh"; then
  echo "[validate.runtime][error] setup/lxc/common.sh must define bubblewrap as the default LXC Codex sandbox package"
  exit 1
fi
if ! grep -q 'PROXMOX_LXC_CODEX_SANDBOX_BINARY=.*bwrap' "${ROOT}/setup/lxc/common.sh"; then
  echo "[validate.runtime][error] setup/lxc/common.sh must define bwrap as the default LXC Codex sandbox binary"
  exit 1
fi
if ! grep -q 'lxc.common.report.binary.status()' "${ROOT}/setup/lxc/common.sh"; then
  echo "[validate.runtime][error] setup/lxc/common.sh must expose a shared runtime-binary status helper"
  exit 1
fi
if ! grep -q 'verify.managed.users()' "${ROOT}/setup/lxc/users.sh"; then
  echo "[validate.runtime][error] setup/lxc/users.sh must verify managed users after apply"
  exit 1
fi
if ! grep -q 'import_playbook: ../../debian/users.yml' "${ROOT}/ansible/proxmox/container/users.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/container/users.yml must import ../../debian/users.yml"
  exit 1
fi
echo "[validate.runtime][ok] setup/lxc/users.sh exposes the Debian-in-LXC default users runner contract"

echo "[validate.runtime] checking Proxmox LXC Samba runner contract..."
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh does not define FEATURE_PLAYBOOKS array"
  exit 1
fi
if ! grep -q '"proxmox/container/samba.file.share.yml"' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh FEATURE_PLAYBOOKS is missing proxmox/container/samba.file.share.yml"
  exit 1
fi
if ! grep -q '/dev/tty' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh is missing TTY input handling (/dev/tty)"
  exit 1
fi
if ! grep -q 'samba.selection.yml' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh is missing samba.selection.yml usage"
  exit 1
fi
if ! grep -q 'SAMBA_EXTRA_VARS_PATH=' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh is missing SAMBA_EXTRA_VARS_PATH"
  exit 1
fi
if ! grep -q 'write.samba.extra.vars.file()' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh is missing write.samba.extra.vars.file()"
  exit 1
fi
if ! grep -q -- '-e "@${SAMBA_EXTRA_VARS_PATH}"' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must pass generated YAML extra-vars with -e @file"
  exit 1
fi
if ! grep -q 'This Samba feature must be run inside the NAS LXC container, not on the Proxmox host.' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must reject Proxmox host execution by default"
  exit 1
fi
if grep -q 'require.proxmox()' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must not require proxmox host execution"
  exit 1
fi
if ! grep -q '/etc/ansible/proxmox/facts' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must use /etc/ansible/proxmox/facts"
  exit 1
fi
if ! grep -q 'ANSIBLE_CORE_VERSION=' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must define ANSIBLE_CORE_VERSION before sourcing release.common.sh"
  exit 1
fi
if ! grep -q 'PROXMOX_RUNTIME_CONTEXT="container"' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must declare the shared container runtime context"
  exit 1
fi
if ! grep -q 'ensure.container.ansible' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must use the container-safe Ansible bootstrap helper"
  exit 1
fi
if ! grep -q 'ensure.root.or.sudo.reexec' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must support sudo re-entry instead of requiring the operator to start as root"
  exit 1
fi
if grep -q 'ensure.managed.ansible' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must not force the managed-target Python bootstrap path inside the LXC"
  exit 1
fi
if ! grep -q 'Continue with Samba base setup and no shares' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must offer a no-mount continue path for base Samba setup"
  exit 1
fi
if ! grep -q 'shares: \[\]' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must serialize explicit empty share selections safely"
  exit 1
fi
echo "[validate.runtime][ok] setup/lxc/samba.sh exposes the structured Samba runner contract"

echo "[validate.runtime] checking Proxmox LXC Network runner contract..."
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh does not define FEATURE_PLAYBOOKS array"
  exit 1
fi
if ! grep -q '"proxmox/container/network.access.yml"' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh FEATURE_PLAYBOOKS is missing proxmox/container/network.access.yml"
  exit 1
fi
if ! grep -q '/dev/tty' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh is missing TTY input handling (/dev/tty)"
  exit 1
fi
if ! grep -q 'lxc.network.selection.yml' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh is missing lxc.network.selection.yml usage"
  exit 1
fi
if ! grep -q 'NETWORK_EXTRA_VARS_PATH=' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh is missing NETWORK_EXTRA_VARS_PATH"
  exit 1
fi
if ! grep -q 'write.network.extra.vars.file()' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh is missing write.network.extra.vars.file()"
  exit 1
fi
if ! grep -q -- '-e "@${NETWORK_EXTRA_VARS_PATH}"' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh must pass generated YAML extra-vars with -e @file"
  exit 1
fi
if ! grep -q 'This network feature must run inside a Debian LXC container, not on the Proxmox host.' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh must reject Proxmox host execution by default"
  exit 1
fi
if ! grep -q 'ensure.container.ansible' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh must use the container-safe Ansible bootstrap helper"
  exit 1
fi
if ! grep -q 'ensure.root.or.sudo.reexec' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh must support sudo re-entry instead of requiring the operator to start as root"
  exit 1
fi
if grep -q 'ensure.managed.ansible' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh must not force the managed-target Python bootstrap path inside the LXC"
  exit 1
fi
if ! grep -q '/etc/ansible/proxmox/facts' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh must use /etc/ansible/proxmox/facts"
  exit 1
fi
if ! awk '
  BEGIN {
    found_defaults=0
    found_lxc_network=0
  }
  /^proxmox_feature_defaults:/ {
    found_defaults=1
  }
  found_defaults && /^[[:space:]]+lxc_network:/ {
    found_lxc_network=1
  }
  END {
    exit !(found_defaults && found_lxc_network)
  }
' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh must set proxmox_feature_defaults.lxc_network in generated vars"
  exit 1
fi
echo "[validate.runtime][ok] setup/lxc/network.sh exposes the structured LXC network runner contract"

echo "[validate.runtime] checking Proxmox Debian LXC runner contract..."
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh does not define FEATURE_PLAYBOOKS array"
  exit 1
fi
if ! grep -q '"proxmox/container/debian.lxc.yml"' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh FEATURE_PLAYBOOKS is missing proxmox/container/debian.lxc.yml"
  exit 1
fi
if ! grep -Eq '"proxmox/container/debian(\.base)?\.yml"' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh FEATURE_PLAYBOOKS is missing proxmox/container/debian.yml"
  exit 1
fi
if ! grep -q 'FEATURE_SUPPORT_FILES=(' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh does not define FEATURE_SUPPORT_FILES array"
  exit 1
fi
if ! grep -q '"debian/netboot.yml"' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh FEATURE_SUPPORT_FILES is missing debian/netboot.yml"
  exit 1
fi
if ! grep -q '"debian/ssh.yml"' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh FEATURE_SUPPORT_FILES is missing debian/ssh.yml"
  exit 1
fi
if ! grep -q '"proxmox/container/debian.base.yml"' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh FEATURE_SUPPORT_FILES is missing proxmox/container/debian.base.yml"
  exit 1
fi
if ! grep -q '"proxmox/common.yml"' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh FEATURE_SUPPORT_FILES is missing proxmox/common.yml"
  exit 1
fi
if ! grep -q '/dev/tty' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh is missing TTY input handling (/dev/tty)"
  exit 1
fi
if ! grep -q 'lxc.debian.selection.yml' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh is missing lxc.debian.selection.yml usage"
  exit 1
fi
if ! grep -q 'DEBIAN_LXC_EXTRA_VARS_PATH=' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh is missing DEBIAN_LXC_EXTRA_VARS_PATH"
  exit 1
fi
if ! grep -q 'write.debian.extra.vars.file()' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh is missing write.debian.extra.vars.file()"
  exit 1
fi
if ! grep -q -- '-e "@${DEBIAN_LXC_EXTRA_VARS_PATH}"' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must pass generated YAML extra-vars with -e @file"
  exit 1
fi
if ! grep -q 'ansible/debian/netboot.yml' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must reference ansible/debian/netboot.yml for Debian web references"
  exit 1
fi
if ! grep -q 'ansible/debian/ssh.yml' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must reference ansible/debian/ssh.yml for shared SSH policy defaults"
  exit 1
fi
if ! grep -q 'show Debian ISO + web reference context' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must expose the combined Debian ISO/web reference context menu label"
  exit 1
fi
if ! grep -q 'Select access mode:' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must prompt for explicit access mode selection"
  exit 1
fi
if ! grep -q 'test access (SSH + default users/passwords)' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must expose the SSH test-access mode option"
  exit 1
fi
if ! grep -q 'access_profile:' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must persist hardening.access_profile into selection YAML"
  exit 1
fi
if ! grep -q 'enable_ssh:' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must persist hardening.enable_ssh into selection YAML"
  exit 1
fi
if ! grep -q 'default logins:' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must print default login guidance for test-access mode"
  exit 1
fi
if grep -q 'show Debian web references' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh still contains the stale menu label 'show Debian web references'"
  exit 1
fi
if ! grep -q 'Web-based Debian netinst references from ansible/debian/netboot.yml' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must print Debian web netinst references in ISO context output"
  exit 1
fi
if ! grep -q 'LXC uses templates, not ISOs' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must keep ISO inventory informational only"
  exit 1
fi
if ! grep -q 'This Debian LXC feature must be run on a Proxmox host, not inside a container.' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must reject container execution by default"
  exit 1
fi
if ! grep -q '/etc/ansible/proxmox/facts' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must use /etc/ansible/proxmox/facts"
  exit 1
fi
if ! grep -q 'ensure.root.or.sudo.reexec' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must support sudo re-entry instead of requiring the operator to start as root"
  exit 1
fi
if ! grep -q 'minimal: debian only' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must present the minimal Debian-only profile option"
  exit 1
fi
if ! grep -q 'tools + debian' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must present the Debian tools profile option"
  exit 1
fi
if grep -q 'ultra-lean samba-only' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must not present Samba-specific hardening labels"
  exit 1
fi
if ! grep -q 'DEBIAN_LXC_TEMPLATE_MAJOR=(10 11 12 13)' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must support the PVE 6-9 Debian major matrix"
  exit 1
fi
if ! grep -q 'pveam available --section system' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must query live templates via pveam available --section system"
  exit 1
fi
if ! grep -q 'DEBIAN_LXC_TEMPLATE_FILENAME_REGEX' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must validate live Debian template filenames"
  exit 1
fi
if ! grep -q 'template.remote.latest.from.major' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must select the latest live template per supported Debian major"
  exit 1
fi
if grep -q 'official URL fallback' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must not advertise direct URL fallback downloads"
  exit 1
fi
if ! grep -q 'download_method:' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must persist template.download_method into the operator selection"
  exit 1
fi
if ! grep -q 'mountpoints: \[\]' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must write mountpoints: [] when no mountpoints are selected"
  exit 1
fi
if ! grep -q "printf '/media/%s" "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must derive container mount targets under /media/{LABEL}"
  exit 1
fi
if ! grep -q 'Detected host mountpoint passthrough candidates:' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must report discovered host mountpoint candidates"
  exit 1
fi
if ! grep -q 'findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must scan the full host mount table for passthrough candidates"
  exit 1
fi
if ! grep -q 'Select mountpoints: single `4`, range `2-4`, CSV `1,3,4`, `ALL`, or `NONE`' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must expose the mountpoint multi-select prompt contract"
  exit 1
fi
if ! grep -q 'parse.mountpoint.selection' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must implement mountpoint multi-select parsing"
  exit 1
fi
if ! grep -q 'normalize.static.ipv4.input' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must normalize bare static IPv4 input before selection write"
  exit 1
fi
if ! grep -q 'prompt.static.ipv4.cidr' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must validate and normalize static IPv4 prompt input"
  exit 1
fi
if ! grep -q 'findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must scan the full container mount table for share discovery"
  exit 1
fi
if ! grep -q 'Select shares: single `4`, range `1-5`, CSV `1,4,6`, mixed `1-4,7`, `ALL`, or `NONE`' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must expose the parser-style multi-select share prompt"
  exit 1
fi
if ! grep -q 'parse.share.selection' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must implement parser-style multi-select share selection"
  exit 1
fi
if ! grep -q 'PROXMOX_SAMBA_MAP_TO_GUEST=' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must expose an explicit map-to-guest override"
  exit 1
fi
if ! grep -q 'PROXMOX_SAMBA_GUEST_ACCOUNT=' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must expose an explicit guest account override"
  exit 1
fi
if ! grep -q 'ANSIBLE_CORE_VERSION=' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must define ANSIBLE_CORE_VERSION before sourcing release.common.sh"
  exit 1
fi
if ! grep -q 'PROXMOX_RUNTIME_CONTEXT="host"' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must declare the shared host runtime context"
  exit 1
fi
debian_preflight_complete_line="$(grep -nF 'Preflight complete. No changes were applied.' "${ROOT}/setup/lxc/debian.sh" | head -n1 | cut -d: -f1 || true)"
debian_ansible_bootstrap_line="$(grep -nF 'ensure.managed.ansible' "${ROOT}/setup/lxc/debian.sh" | head -n1 | cut -d: -f1 || true)"
if [[ -z "${debian_preflight_complete_line}" || -z "${debian_ansible_bootstrap_line}" ]] \
  || ((debian_ansible_bootstrap_line <= debian_preflight_complete_line)); then
  echo "[validate.runtime][error] setup/lxc/debian.sh must defer Ansible/Python bootstrap until after shell-only preflight"
  exit 1
fi
echo "[validate.runtime][ok] setup/lxc/debian.sh exposes the structured Debian LXC runner contract"

if ! grep -q 'mountpoints: \[\]' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must carry mountpoints: [] in safe defaults"
  exit 1
fi
if ! grep -Fq 'proxmox_lxc_debian_effective.mountpoints | default([], true)' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml mountpoint loop must default null mountpoints to an empty list"
  exit 1
fi
if ! grep -q 'Mount selected container rootfs for mountpoint preparation' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must mount the CT rootfs before preparing bind-mount targets"
  exit 1
fi
if grep -Fq "regex_search(\"'([^']+)'\", '\\1')" "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must not derive rootfs path via capture-group regex that can return list-shaped output"
  exit 1
fi
if ! grep -q 'Resolve mounted container rootfs path as a scalar string' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must resolve mounted rootfs path as a scalar string"
  exit 1
fi
if ! grep -q 'Assert mounted container rootfs path resolved to scalar string' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must guard against list-shaped rootfs path values"
  exit 1
fi
if ! grep -q 'Ensure parent directories for selected mountpoint targets exist inside mounted container rootfs' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must create parent directories for selected mountpoint targets inside the mounted CT rootfs"
  exit 1
fi
if ! grep -q 'Assert selected mountpoints were attached to container config' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must verify mpX attachment in pct config"
  exit 1
fi
if ! grep -q 'Assert selected mountpoints are visible inside the running container' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must verify selected mounts from inside the running container"
  exit 1
fi
if ! grep -q 'Ensure selected container console settings support interactive login' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must apply interactive console settings"
  exit 1
fi
if ! grep -q 'Wait for DHCP IPv4 assignment on selected container' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must wait for DHCP assignment before final IPv4 summary capture"
  exit 1
fi
if ! grep -q 'Capture runner-normalized static IPv4 CIDR for pct create' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must capture the runner-normalized static IPv4 CIDR before pct create"
  exit 1
fi
if ! grep -q 'Append default /24 when static IPv4 selection is a bare address' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must support a simple bare-IPv4 to /24 fallback"
  exit 1
fi
if ! grep -q 'Report effective static IPv4 payload before pct create' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must report the effective static IPv4 payload before pct create"
  exit 1
fi
if ! grep -q 'Report effective pct net0 string before pct create' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must report the final pct net0 string before pct create"
  exit 1
fi
if ! grep -q 'Assert effective static IPv4 and gateway syntax before pct create' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must validate the effective static IPv4 and gateway syntax before pct create"
  exit 1
fi
if grep -q 'Normalize static IPv4 source input for pct create' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must not re-normalize runner-validated static IPv4 via the stale regex path"
  exit 1
fi

echo "[validate.runtime] checking VLAN playbook safety contract..."
if ! grep -q 'proxmox_vlan_operator_selection' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml does not consume proxmox_vlan_operator_selection"
  exit 1
fi
if ! grep -q 'oob_console_ack' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml does not enforce oob_console_ack"
  exit 1
fi
if ! grep -q 'interfaces.bak.proxmox-vlan' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml is missing rollback backup marker"
  exit 1
fi
if grep -Eq '^[[:space:]]+bridge-fd[[:space:]]+0([[:space:]]|$)' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must not generate bridge-fd 0"
  exit 1
fi
if ! grep -q 'Collect selected physical NIC IPv4 methods by interface tokens' "${ROOT}/ansible/proxmox/tasks/data-link.candidate.yml" \
  || ! grep -q 'proxmox_vlan_data_nic_emit_manual' "${ROOT}/ansible/proxmox/tasks/data-link.candidate.yml"; then
  echo "[validate.runtime][error] canonical DATA-Link task must count and canonicalize selected data NIC IPv4 stanzas"
  exit 1
fi
if ! grep -q 'tasks/data-link.candidate.yml' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must include the canonical DATA-Link candidate task"
  exit 1
fi
if ! grep -q 'tasks/data-link.ifreload.validate.yml' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must include shared no-action ifreload validation"
  exit 1
fi
if ! grep -q 'Parse complete DATA-Link candidate interface list' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must parse the complete candidate before mutation"
  exit 1
fi
if ! grep -q 'FEATURE_SUPPORT_FILES=(' "${ROOT}/setup/vlan.sh" \
  || ! grep -q 'proxmox/tasks/data-link.candidate.yml' "${ROOT}/setup/vlan.sh" \
  || ! grep -q 'proxmox/tasks/data-link.ifreload.validate.yml' "${ROOT}/setup/vlan.sh" \
  || ! grep -q 'proxmox/templates/data-link.interfaces.j2' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh must fetch and publish the DATA-Link task includes and template"
  exit 1
fi
if [[ "$(grep -Ec '^[[:space:]]+- -n$' "${ROOT}/ansible/proxmox/tasks/data-link.ifreload.validate.yml")" -ne 2 ]]; then
  echo "[validate.runtime][error] both DATA-Link ifreload checks must use no-action mode"
  exit 1
fi
if ! grep -q 'Search rendered candidate for a literal backslash-n escape' "${ROOT}/ansible/proxmox/tasks/data-link.candidate.yml"; then
  echo "[validate.runtime][error] canonical DATA-Link task must reject literal newline escapes"
  exit 1
fi
if ! grep -q 'Report write mode completion (staged config only)' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must report that write mode stages config without live apply"
  exit 1
fi
if ! grep -q 'proxmox_vlan_fatal_parser_warning_pattern' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must reject zero-exit structural parser warnings"
  exit 1
fi
if grep -q 'ip link set dev.*master' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must not force runtime bridge attachment"
  exit 1
fi
if ! grep -q 'Assert selected data NIC is attached after normal interface reload' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must verify NIC attachment after normal reload"
  exit 1
fi
if ! grep -q 'Capture selected bridge port list after apply' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must collect bridge port diagnostics after apply"
  exit 1
fi
echo "[validate.runtime][ok] ansible/proxmox/vlan.yml includes selection/oob/rollback safeguards"

echo "[validate.runtime] checking Samba playbook safety contract..."
if ! grep -q 'This Samba feature must run inside a Debian LXC container, not on the Proxmox host.' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must fail when run on a Proxmox host"
  exit 1
fi
if ! grep -q 'testparm' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must validate generated config with testparm"
  exit 1
fi
if ! grep -q 'No Samba shares were selected. Continuing with base Samba setup only.' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must support no-share base setup mode"
  exit 1
fi
if ! grep -q 'Normalize Samba selection payload' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must build selection payload in its own task"
  exit 1
fi
if ! grep -q 'Build effective Samba model' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must build the effective Samba model in a separate task"
  exit 1
fi
if ! grep -q 'Report effective Samba share count before smb.conf render' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must report effective share count before smb.conf render"
  exit 1
fi
if ! grep -q 'Assert guest browse lists selected shares when guest mode is enabled' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must verify guest browse output for selected shares"
  exit 1
fi
if ! grep -q 'guest account =' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must manage the Samba guest account explicitly"
  exit 1
fi
if ! grep -q 'writable: %s' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must persist per-share writability instead of hard-coding writable=true"
  exit 1
fi
if ! grep -q '/etc/samba/smb.conf' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must manage /etc/samba/smb.conf"
  exit 1
fi
if ! grep -q 'openssh-server' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must install openssh-server"
  exit 1
fi
if ! grep -q 'avahi-daemon' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must install avahi-daemon"
  exit 1
fi
if ! grep -q 'catia' "${ROOT}/ansible/proxmox/container/samba.file.share.yml" \
   || ! grep -q 'fruit' "${ROOT}/ansible/proxmox/container/samba.file.share.yml" \
   || ! grep -q 'streams_xattr' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must configure macOS vfs objects"
  exit 1
fi
if ! grep -q 'Set UFW default-deny ingress and egress policy' "${ROOT}/ansible/proxmox/container/samba.file.share.yml" \
   || ! grep -q 'Allow SMB only from trusted subnets on the selected data interface' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must enforce interface-scoped, default-deny UFW policy"
  exit 1
fi
if ! grep -q '_RO]' "${ROOT}/ansible/proxmox/container/samba.file.share.yml" \
   || ! grep -q '_RW]' "${ROOT}/ansible/proxmox/container/samba.file.share.yml" \
   || ! grep -q 'write list =' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must render separate guest-read and authenticated-write shares"
  exit 1
fi
if ! grep -q 'Stop and mask SSH for the console-only ingest appliance' "${ROOT}/ansible/proxmox/container/samba.file.share.yml" \
   || ! grep -q 'Require SSH listener to be absent for console-only mode' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must stop SSH and verify that port 22 is absent"
  exit 1
fi
echo "[validate.runtime][ok] samba.file.share.yml includes isolated Samba/SSH/firewall safeguards"

echo "[validate.runtime] checking LXC network playbook safety contract..."
if ! grep -q 'This LXC network feature must run inside a Debian LXC container, not on the Proxmox host.' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must fail when run on a Proxmox host"
  exit 1
fi
if ! grep -q 'proxmox_lxc_network_container_facts_path' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must expose container_facts path override"
  exit 1
fi
if ! grep -q 'proxmox_lxc_network_runtime_facts_path' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must expose runtime_facts path override"
  exit 1
fi
if ! grep -q 'proxmox_lxc_network_selection_path' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must expose selection path override"
  exit 1
fi
if ! grep -q 'Build effective runtime configuration' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must build effective configuration"
  exit 1
fi
if ! grep -q 'Apply access profile behavior overrides' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must enforce access profile overrides"
  exit 1
fi
if ! grep -q 'Ensure sudoers drop-in directory exists' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must persist managed sudoers for non-root users"
  exit 1
fi
if ! grep -q 'Install local-LAN access packages' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must install local-LAN access packages"
  exit 1
fi
if ! grep -q 'Write managed SSH policy include' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must write SSH include policy"
  exit 1
fi
if ! grep -q 'Resolve SSH service name' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must resolve SSH service name"
  exit 1
fi
if ! grep -q 'Enable and restart SSH service' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must start SSH service when enabled"
  exit 1
fi
if ! grep -q 'Configure UFW local-subnet SSH allow rules' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must apply UFW local-subnet allow rules"
  exit 1
fi
if ! grep -q 'Enable UFW' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must enable UFW when enabled"
  exit 1
fi
if ! grep -q 'Validate FUSE device for container client tooling' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must validate /dev/fuse availability when FUSE tooling is enabled"
  exit 1
fi
if ! grep -q 'Persist LXC network runtime facts' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must persist runtime facts"
  exit 1
fi
if ! grep -q 'Report apply summary' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must print an apply summary"
  exit 1
fi
if ! grep -q 'Report preflight summary' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must print preflight summary"
  exit 1
fi
if ! grep -q 'Probe DNS resolution' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must include DNS probe"
  exit 1
fi
if ! grep -q 'Probe internet IPv4' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must include internet probe"
  exit 1
fi
echo "[validate.runtime][ok] network.access.yml includes container networking hardening and runtime reporting safeguards"

echo "[validate.runtime] checking Debian LXC playbook safety contract..."
if ! grep -q 'This Debian LXC feature must run on the Proxmox host.' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must fail when not run on the Proxmox host"
  exit 1
fi
if ! grep -q 'pct' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must manage containers with pct"
  exit 1
fi
if ! grep -q 'pveam' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must handle Debian template download/update flow"
  exit 1
fi
if ! grep -q 'lxc.debian.selection.yml' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must consume lxc.debian.selection.yml"
  exit 1
fi
if ! grep -q 'rootfs_storage' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must validate rootfs storage inputs"
  exit 1
fi
if ! grep -q 'full-upgrade' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must run full Debian system update before package profile install"
  exit 1
fi
if ! grep -q 'APT_LISTCHANGES_FRONTEND=none' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must set APT_LISTCHANGES_FRONTEND=none for noninteractive bootstrap upgrades"
  exit 1
fi
if ! grep -q 'TMPDIR=/tmp' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must enforce TMPDIR=/tmp for apt/dpkg bootstrap reliability"
  exit 1
fi
if ! grep -q 'LC_ALL=C.UTF-8' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must enforce LC_ALL=C.UTF-8 for deterministic locale behavior"
  exit 1
fi
if ! grep -q '/tmp/user/0' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must prepare /tmp/user/0 for package postinst helpers"
  exit 1
fi
if ! grep -q 'dpkg.*--configure.*-a' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must attempt dpkg --configure -a recovery before full-upgrade"
  exit 1
fi
if ! grep -q "apt-get', '-y', '-f', 'install" "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must attempt apt-get -y -f install recovery before full-upgrade"
  exit 1
fi
if ! grep -q 'pct' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must configure the container through pct exec"
  exit 1
fi
if ! grep -q 'openssh-server' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must install openssh-server"
  exit 1
fi
if ! grep -q 'python3-venv' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must pre-seed python3-venv for container-local feature runners"
  exit 1
fi
if grep -q 'node' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must stay light and must not install Node tooling"
  exit 1
fi
if ! grep -q 'profile in \['"'"'minimal'"'"', '"'"'tools'"'"'\]' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must expose the minimal/tools profile model"
  exit 1
fi
if ! grep -q 'ufw allow from' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must support container UFW subnet rules"
  exit 1
fi
if ! grep -q 'sshd' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must validate SSH configuration"
  exit 1
fi
if ! grep -q 'Ensure access users exist inside the container' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must provision access users for test-access mode"
  exit 1
fi
if ! grep -q 'Set access-user passwords inside the container' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must apply default access credentials for test-access mode"
  exit 1
fi
if ! grep -q 'AllowUsers' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must manage SSH AllowUsers for access users"
  exit 1
fi
if ! grep -q 'PasswordAuthentication' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must manage PasswordAuthentication for SSH test access"
  exit 1
fi
if ! grep -q 'Load shared Debian SSH defaults' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must load shared Debian SSH defaults from ansible/debian/ssh.yml"
  exit 1
fi
if ! grep -q 'Load non-LXC Proxmox baseline defaults for policy boundary clarity' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must include boundary load for non-LXC baseline defaults"
  exit 1
fi
if ! grep -q 'proxmox_common_defaults_path' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must resolve proxmox_common_defaults_path"
  exit 1
fi
if ! grep -q 'Ensure SSH host keys exist inside the container' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must generate SSH host keys for Debian LXC access"
  exit 1
fi
if ! grep -q 'Restart SSH service inside the container' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must restart SSH after applying managed policy"
  exit 1
fi
if ! grep -q 'ssh_listener_state' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml runtime facts must include SSH listener state"
  exit 1
fi
if ! grep -q 'Capture system Python 3 version from the container' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must capture container system Python version for Samba runtime handoff"
  exit 1
fi
if ! grep -q 'samba_runner_ready' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml runtime facts must include Samba runner readiness"
  exit 1
fi
if ! grep -q 'Capture Debian version details from the container' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must capture Debian version details"
  exit 1
fi
if ! grep -q 'Capture default IPv4 route from the container' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must capture default-route status"
  exit 1
fi
if ! grep -q 'Capture container resolver nameservers' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must capture resolver nameserver status"
  exit 1
fi
if ! grep -q 'Probe internet IPv4 connectivity from the container' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must probe internet IPv4 connectivity"
  exit 1
fi
if ! grep -q 'Probe DNS resolution from the container' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml must probe DNS resolution"
  exit 1
fi
if ! grep -q 'default_login_pairs' "${ROOT}/ansible/proxmox/container/debian.base.yml"; then
  echo "[validate.runtime][error] debian.base.yml runtime facts must include default login guidance"
  exit 1
fi
if ! grep -q 'root' "${ROOT}/ansible/proxmox/common.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/common.yml must include root in its baseline user list"
  exit 1
fi
if ! grep -q 'proxmox' "${ROOT}/ansible/proxmox/common.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/common.yml must include proxmox in its baseline user list"
  exit 1
fi
if ! grep -q 'agent' "${ROOT}/ansible/proxmox/common.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/common.yml must include agent in its baseline user list"
  exit 1
fi
if ! grep -q 'proxmox_lxc_codex_runtime_packages:' "${ROOT}/ansible/proxmox/container/common.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/container/common.yml must define the LXC Codex runtime package contract"
  exit 1
fi
if ! grep -q 'bubblewrap' "${ROOT}/ansible/proxmox/container/common.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/container/common.yml must define bubblewrap as an LXC Codex runtime package"
  exit 1
fi
if ! grep -q 'proxmox_lxc_codex_runtime_binaries:' "${ROOT}/ansible/proxmox/container/common.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/container/common.yml must define the LXC Codex runtime binary contract"
  exit 1
fi
if ! grep -q 'bwrap' "${ROOT}/ansible/proxmox/container/common.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/container/common.yml must define bwrap as the LXC Codex runtime binary"
  exit 1
fi
if ! grep -q 'template_policy:' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] ansible/group_vars/proxmox.yml must define proxmox_lxc_debian.template_policy"
  exit 1
fi
if ! grep -q 'filename_regex:' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox template policy must define the dynamic Debian filename contract"
  exit 1
fi
if ! grep -q 'selection: "latest_version_per_supported_major"' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox template policy must select the latest version per supported major"
  exit 1
fi
if ! grep -q 'allow_direct_url_fallback: false' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox template policy must fail closed instead of using direct URL downloads"
  exit 1
fi
if ! grep -q 'access_profile: "local_only"' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox LXC hardening defaults must include access_profile"
  exit 1
fi
if ! grep -q 'lxc_network:' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox feature defaults must define lxc_network"
  exit 1
fi
if ! grep -q 'lxc_network:' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml safe defaults must define lxc_network"
  exit 1
fi
if ! grep -q 'expected_dns: "10.0.0.1"' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox LXC hardening defaults must include expected_dns"
  exit 1
fi
if ! grep -q 'internet_probe_ipv4' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox LXC defaults must include internet_probe_ipv4"
  exit 1
fi
if ! grep -q 'python3-venv' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox Debian LXC package defaults must include python3-venv"
  exit 1
fi
if ! grep -q 'facts_dir: "/etc/ansible/proxmox/facts"' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox LXC network defaults must define facts_dir"
  exit 1
fi
if ! grep -q 'ensure.container.ansible()' "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] release.common.sh must expose a container-safe Ansible bootstrap helper"
  exit 1
fi
if ! grep -q 'Using container Python strategy=' "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] release.common.sh must report the detected container Python strategy"
  exit 1
fi
if ! grep -q 'ensurepip --version' "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] release.common.sh must verify ensurepip availability before building the container Ansible venv"
  exit 1
fi
if ! grep -q 'Removing incomplete or out-of-policy' "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] release.common.sh must clean up incomplete or out-of-policy Ansible venvs"
  exit 1
fi
if ! grep -q 'select.ansible.bootstrap.python()' "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] release.common.sh must expose a shared bootstrap selector for native system Python Ansible installs"
  exit 1
fi
if ! grep -q 'Using native system Python for Ansible bootstrap' "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] release.common.sh must prefer native system Python for supported host Ansible bootstrap flows"
  exit 1
fi
if ! grep -q 'python${python_mm}-venv' "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] release.common.sh must install version-matched pythonX.Y-venv when system ensurepip is unavailable"
  exit 1
fi
echo "[validate.runtime] checking canonical managed Ansible dispatch..."
for marker in \
  '/opt/ansible-venv' \
  'ANSIBLE_VENV_BIN="${ANSIBLE_VENV}/bin/ansible-playbook"' \
  'PROXMOX_ANSIBLE_CORE_VERSION' \
  'ansible.runtime.prepare()' \
  'ANSIBLE_RUNTIME_VARS_PATH' \
  'bootstrap_needs_target_python_build' \
  'ansible.runtime.require()' \
  'ansible.runtime.run()' \
  'ansible_python_interpreter=${ANSIBLE_RUNTIME_TARGET_PYTHON'; do
  if ! grep -Fq -- "${marker}" "${ROOT}/bootstrap/ansible.runtime.sh"; then
    echo "[validate.runtime][error] canonical Ansible helper is missing marker: ${marker}"
    exit 1
  fi
done
for runner in \
  setup/vlan.sh \
  setup/network.sh \
  setup/cli.codex.sh \
  setup/lxc/debian.sh \
  setup/lxc/samba.sh \
  setup/lxc/network.sh \
  setup/lxc/codex.sh \
  setup/lxc/users.sh \
  bootstrap/metal.sh; do
  if ! grep -Fq 'ansible.runtime.run' "${ROOT}/${runner}"; then
    echo "[validate.runtime][error] ${runner} bypasses canonical managed Ansible dispatch"
    exit 1
  fi
done
for runner in \
  setup/vlan.sh \
  setup/network.sh \
  setup/cli.codex.sh \
  setup/lxc/debian.sh \
  setup/lxc/samba.sh \
  setup/lxc/network.sh \
  setup/lxc/codex.sh \
  setup/lxc/users.sh; do
  if grep -Eq '^(PYTHON_VERSION|PYTHON_MAJOR_MINOR|MANAGED_TARGET_PYTHON_HOME)=' "${ROOT}/${runner}"; then
    echo "[validate.runtime][error] ${runner} duplicates canonical Python runtime policy"
    exit 1
  fi
done
for runner in \
  setup/vlan.sh \
  setup/network.sh \
  setup/cli.codex.sh \
  setup/lxc/debian.sh \
  setup/lxc/samba.sh \
  setup/lxc/network.sh \
  setup/lxc/codex.sh \
  setup/lxc/users.sh; do
  if grep -Fq 'MANAGED_TARGET_HANDOFF_MARKER' "${ROOT}/${runner}"; then
    echo "[validate.runtime][error] ${runner} treats a managed Python handoff marker as a feature prerequisite"
    exit 1
  fi
  if grep -Eq '\[\[[^]]*MANAGED_TARGET_PYTHON_PATH' "${ROOT}/${runner}"; then
    echo "[validate.runtime][error] ${runner} directly gates execution on a provisional managed Python path"
    exit 1
  fi
  if grep -Fq 'Run the baseline bootstrap first' "${ROOT}/${runner}"; then
    echo "[validate.runtime][error] ${runner} retains a blanket baseline-bootstrap blocker"
    exit 1
  fi
  if grep -Fq 'PROXMOX_FEATURE_SKIP_BASELINE_CHECK' "${ROOT}/${runner}"; then
    echo "[validate.runtime][error] ${runner} retains the obsolete baseline readiness bypass"
    exit 1
  fi
done
for runner in \
  setup/firewall.sh \
  setup/lxc/storage.sh \
  setup/lxc/egress.sh; do
  if grep -Eq 'source\.release\.common|ensure\.(managed|container)\.ansible|ansible\.runtime\.' "${ROOT}/${runner}"; then
    echo "[validate.runtime][error] shell-only runner ${runner} unexpectedly depends on the Ansible/Python bootstrap"
    exit 1
  fi
done
if grep -Eq '(^|[^[:alnum:]_])lsb(_release)?([^[:alnum:]_]|$)' \
  "${ROOT}/bootstrap/ansible.runtime.sh" \
  "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] canonical runtime detection must use /etc/os-release and must not require LSB tooling"
  exit 1
fi
if grep -Fq 'meta: end_play' "${ROOT}/ansible/debian/ansible.venv.yml"; then
  echo "[validate.runtime][error] ansible.venv.yml still terminates the caller play"
  exit 1
fi
if ! grep -Fq 'Validate canonical managed ansible-playbook after maintenance' "${ROOT}/ansible/debian/ansible.venv.yml"; then
  echo "[validate.runtime][error] ansible.venv.yml does not validate the final canonical runtime"
  exit 1
fi
echo "[validate.runtime][ok] production runners use the canonical managed Ansible runtime"
echo "[validate.runtime] running platform/runtime policy matrix..."
bash "${ROOT}/tests/unit/ansible_runtime_policy_test.sh"
bash "${ROOT}/tests/unit/debian_lxc_template_policy_test.sh"
bash "${ROOT}/tests/unit/network_snapshot_policy_test.sh"
if ! bash -u -c '
  log() { :; }
  log.error() { :; }
  source "$1"

  ansible.version.line.matches.policy "ansible-playbook [core ${ANSIBLE_CORE_VERSION}]"
  ! ansible.version.line.matches.policy "ansible-playbook [core 0.0.0]"
  ! ansible.version.line.matches.policy "ansible-playbook core ${ANSIBLE_CORE_VERSION}"

  calls=()
  ensure.managed.ansible() { calls+=("managed-ansible"); }
  fetch.playlist() { calls+=("playlist"); }
  fetch.groupvars() { calls+=("group-vars"); }
  merge.groupvars() { calls+=("merge"); }
  run.playlist() { calls+=("run"); }

  SKIP_ANSIBLE=0
  maybe.run.ansible
  [[ "${calls[*]}" == "managed-ansible playlist group-vars merge run" ]]
' _ "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] shared Ansible version policy or release bootstrap call order is invalid"
  exit 1
fi
echo "[validate.runtime][ok] shared Ansible version policy and release bootstrap call order are valid"
if ! grep -q 'ensure.ansible.for.context()' "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] managed and container Ansible paths must share the detected runtime policy"
  exit 1
fi
if ! grep -q 'PROXMOX_RUNTIME_EXPECT_PVE_MAJOR="9"' "${ROOT}/bootstrap/release.9.1.sh"; then
  echo "[validate.runtime][error] bootstrap/release.9.1.sh must declare the PVE 9 runtime contract"
  exit 1
fi
if ! grep -q 'PROXMOX_RUNTIME_EXPECT_DEBIAN_CODENAME="trixie"' "${ROOT}/bootstrap/release.9.1.sh"; then
  echo "[validate.runtime][error] bootstrap/release.9.1.sh must declare the Trixie runtime contract"
  exit 1
fi
if grep -Fq 'proxmox_users_skip_container_safety_checks: "{{ proxmox_users_skip_container_safety_checks |' "${ROOT}/ansible/debian/users.yml"; then
  echo "[validate.runtime][error] users.yml must not define the container safety flag recursively"
  exit 1
fi
if ! grep -Fq 'proxmox_users_skip_container_safety_checks_effective: "{{ proxmox_users_skip_container_safety_checks | default(false) | bool }}"' "${ROOT}/ansible/debian/users.yml"; then
  echo "[validate.runtime][error] users.yml must derive a non-recursive effective container safety flag"
  exit 1
fi
if grep -Eq '^[[:space:]]+when: not proxmox_users_skip_container_safety_checks$' "${ROOT}/ansible/debian/users.yml"; then
  echo "[validate.runtime][error] users.yml safety tasks must use the effective container safety flag"
  exit 1
fi
if [[ "$(grep -Ec '^[[:space:]]+when: not proxmox_users_skip_container_safety_checks_effective$' "${ROOT}/ansible/debian/users.yml" || true)" -ne 9 ]]; then
  echo "[validate.runtime][error] users.yml must apply the effective container safety flag to all nine host safety tasks"
  exit 1
fi
if ! grep -q 'Require a catalog-backed template download method' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must enforce catalog-backed template downloads"
  exit 1
fi
if grep -q "proxmox_lxc_debian_template_download_method == 'url'" "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must not retain the direct URL fallback path"
  exit 1
fi
echo "[validate.runtime][ok] Debian LXC host/base playbooks include template, pct, SSH, and light-hardening safeguards"

echo "[validate.runtime] checking Debian LXC bootstrap reference playbook..."
if ! grep -q 'pct create' "${ROOT}/ansible/proxmox/container/bootstrap/debian.create.yml"; then
  echo "[validate.runtime][error] bootstrap/debian.create.yml must capture canonical pct create usage"
  exit 1
fi
if ! grep -q 'proxmox_lxc' "${ROOT}/ansible/proxmox/container/bootstrap/debian.create.yml"; then
  echo "[validate.runtime][error] bootstrap/debian.create.yml must define a proxmox_lxc variable model"
  exit 1
fi
if ! grep -q 'ssh_public_keys_file' "${ROOT}/ansible/proxmox/container/bootstrap/debian.create.yml"; then
  echo "[validate.runtime][error] bootstrap/debian.create.yml must retain SSH key bootstrap inputs"
  exit 1
fi
if ! grep -q 'nameserver' "${ROOT}/ansible/proxmox/container/bootstrap/debian.create.yml"; then
  echo "[validate.runtime][error] bootstrap/debian.create.yml must retain DNS bootstrap inputs"
  exit 1
fi
if ! grep -q 'tags' "${ROOT}/ansible/proxmox/container/bootstrap/debian.create.yml"; then
  echo "[validate.runtime][error] bootstrap/debian.create.yml must retain tag/bootstrap metadata inputs"
  exit 1
fi
echo "[validate.runtime][ok] Debian LXC bootstrap reference playbook captures the broader create model"

echo "[validate.runtime] checking hardware helper regression guards..."
if grep -q "regex_search(' master (\\\\S+)', '\\\\1')" "${ROOT}/ansible/proxmox/helper/hardware.yml"; then
  echo "[validate.runtime][error] helper/hardware.yml uses unsafe regex_search capture for bridge_member"
  exit 1
fi
if grep -q "select('search', ' master ' ~ proxmox_management_bridge ~ ' ')" "${ROOT}/ansible/proxmox/helper/hardware.yml"; then
  echo "[validate.runtime][error] hardware.yml uses fragile bridge-link search for management ports"
  exit 1
fi
if ! grep -q '/sys/class/net/.*/brif' "${ROOT}/ansible/proxmox/helper/hardware.yml" \
   && ! grep -q '/sys/class/net/.*brif' "${ROOT}/ansible/proxmox/helper/hardware.yml"; then
  echo "[validate.runtime][error] hardware.yml should derive bridge ports from /sys/class/net/<bridge>/brif"
  exit 1
fi
if ! grep -q 'bridge_ports' "${ROOT}/ansible/proxmox/helper/hardware.yml"; then
  echo "[validate.runtime][error] hardware.yml should persist management.bridge_ports"
  exit 1
fi
if ! grep -q 'discovered.bridge_ports' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] vlan.yml should include bridge_ports in management-path mismatch diagnostics"
  exit 1
fi
if grep -R --exclude='validate.runtime.sh' '/etc/devsguide/proxmox' "${ROOT}/setup" "${ROOT}/ansible" "${ROOT}/actions" >/dev/null 2>&1; then
  echo "[validate.runtime][error] /etc/devsguide/proxmox paths are not allowed; use /etc/ansible/proxmox"
  exit 1
fi
if ! grep -q '/etc/ansible/proxmox/facts' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh must use /etc/ansible/proxmox/facts"
  exit 1
fi
if ! grep -q '/etc/ansible/proxmox/facts' "${ROOT}/ansible/proxmox/helper/hardware.yml"; then
  echo "[validate.runtime][error] helper/hardware.yml must use /etc/ansible/proxmox/facts"
  exit 1
fi
if ! grep -q '/etc/ansible/proxmox/facts' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] vlan.yml must use /etc/ansible/proxmox/facts"
  exit 1
fi
if ! grep -q 'hardware.nics.tsv' "${ROOT}/ansible/proxmox/helper/hardware.yml"; then
  echo "[validate.runtime][error] helper/hardware.yml must write hardware.nics.tsv"
  exit 1
fi
if ! grep -q 'pci_label' "${ROOT}/ansible/proxmox/helper/hardware.yml"; then
  echo "[validate.runtime][error] helper/hardware.yml must export pci_label for the VLAN UI"
  exit 1
fi
if ! grep -q '/sys/class/net/{{ item }}/device' "${ROOT}/ansible/proxmox/helper/hardware.yml"; then
  echo "[validate.runtime][error] helper/hardware.yml must filter candidate NICs to physical interfaces"
  exit 1
fi
echo "[validate.runtime][ok] helper/hardware.yml avoids unsafe bridge-member parsing, exports NIC identity, and keeps facts under /etc/ansible/proxmox/facts"
echo "[validate.runtime][ok] management bridge/uplink discovery contract is valid"

echo "[validate.runtime] checking publish wiring contract..."
if grep -qE '(^|[[:space:]])proxmox/' "${ROOT}/ansible/debian/install.playbooks.txt"; then
  echo "[validate.runtime][error] ansible/debian/install.playbooks.txt must remain Debian-only (found proxmox entry)"
  exit 1
fi
if ! grep -q 'load.runner.array_from_script' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must parse runner arrays through a shared loader"
  exit 1
fi
if ! grep -q 'load.setup.runner.refs' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must load setup runner feature refs through the shared loader"
  exit 1
fi
if ! grep -q 'FEATURE_SUPPORT_FILES' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must publish FEATURE_SUPPORT_FILES dependencies"
  exit 1
fi
if ! grep -q 'setup_lxc_codex_support' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must collect support refs for setup/lxc/codex.sh"
  exit 1
fi
if ! grep -q 'setup_lxc_users_support' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must collect support refs for setup/lxc/users.sh"
  exit 1
fi
if ! grep -q 'setup_debian_lxc_support' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must collect support refs for setup/lxc/debian.sh"
  exit 1
fi
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh FEATURE_PLAYBOOKS array not found for publish parsing"
  exit 1
fi
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/network.sh"; then
  echo "[validate.runtime][error] setup/network.sh FEATURE_PLAYBOOKS array not found for publish parsing"
  exit 1
fi
if ! grep -q 'setup/lxc/samba.sh' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must publish the structured Samba runner path"
  exit 1
fi
if ! grep -q 'setup.cli.codex.sh' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must publish setup.cli.codex.sh"
  exit 1
fi
if ! grep -q 'setup/network.sh' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must publish the structured network runner path"
  exit 1
fi
if ! grep -q 'setup/network-link.sh' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must publish the structured DATA-Link runner path"
  exit 1
fi
if ! grep -q 'setup/lxc/debian.sh' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must publish the structured Debian LXC runner path"
  exit 1
fi
if ! grep -q 'setup/lxc/network.sh' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must publish the structured LXC network runner path"
  exit 1
fi
if ! grep -q 'setup/lxc/codex.sh' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must publish the structured LXC Codex runner path"
  exit 1
fi
if ! grep -q 'setup/lxc/users.sh' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must publish the structured LXC users runner path"
  exit 1
fi
if [[ -f "${ROOT}/setup/vlan.playbooks.txt" ]]; then
  echo "[validate.runtime][error] setup/vlan.playbooks.txt should not exist (array model is source-of-truth)"
  exit 1
fi
echo "[validate.runtime][ok] publish wiring follows setup/vlan.sh FEATURE_PLAYBOOKS model"

echo "[validate.runtime] checking remote VM restore CLI contracts..."
"${ROOT}/actions/validate.vm.restore.sh"

echo "[validate.runtime] checking shell syntax..."
bash -n "${ROOT}/bootstrap/release.6.4.sh"
bash -n "${ROOT}/bootstrap/release.9.1.sh"
bash -n "${ROOT}/bootstrap/release.common.sh"
bash -u -c 'log(){ :; }; log.error(){ :; }; source "${1}"; : "${ANSIBLE_CORE_VERSION:?}" "${ANSIBLE_CORE_SPEC:?}" "${MANAGED_TARGET_PYTHON_HOME:?}" "${MANAGED_TARGET_PYTHON_PATH:?}"' _ "${ROOT}/bootstrap/release.common.sh"
bash -n "${ROOT}/setup/vlan.sh"
bash -n "${ROOT}/setup/network-link.sh"
bash -n "${ROOT}/setup/network.sh"
bash -n "${ROOT}/setup/cli.codex.sh"
bash -n "${ROOT}/setup/lxc/debian.sh"
bash -n "${ROOT}/setup/lxc/samba.sh"
bash -n "${ROOT}/setup/lxc/network.sh"
bash -n "${ROOT}/setup/lxc/codex.sh"
bash -n "${ROOT}/setup/lxc/users.sh"
bash -n "${ROOT}/setup/vm/restore.sh"
bash -n "${ROOT}/cli/lib/restore.common.sh"
bash -n "${ROOT}/cli/ssh/sync.sh"
bash -n "${ROOT}/cli/storage/temp.sh"
bash -n "${ROOT}/cli/rsync/fetch.sh"
bash -n "${ROOT}/actions/validate.vm.restore.sh"
bash -n "${ROOT}/actions/validate.release.sh"
echo "[validate.runtime][ok] shell syntax checks passed"

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "[validate.runtime][warn] ansible-playbook not found; skipping check-mode validation"
  exit 0
fi

ANSIBLE_CHECK_PYTHON="${ANSIBLE_CHECK_PYTHON:-$(command -v python3)}"
if [[ ! -x "${ANSIBLE_CHECK_PYTHON}" ]]; then
  echo "[validate.runtime][error] CI check-mode Python is unavailable: ${ANSIBLE_CHECK_PYTHON}"
  exit 1
fi

run_package_check() {
  local release_label="$1"
  shift
  echo "[validate.runtime] simulating install.packages.yml for ${release_label} ..."
  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook \
    -i localhost, \
    -c local \
    -e "@${ROOT}/ansible/group_vars/all.yml" \
    -e host_platform_family=proxmox \
    -e apt_skip_cache_refresh=true \
    "$@" \
    -e "ansible_python_interpreter_managed=${ANSIBLE_CHECK_PYTHON}" \
    --check \
    "${ROOT}/ansible/debian/install.packages.yml"
}

run_package_check "9.1/Trixie" \
  -e "@${ROOT}/ansible/group_vars/trixie.yml" \
  -e "@${ROOT}/ansible/release/9.1/group_vars/all.yml"
run_package_check "6.4/Buster" \
  -e "@${ROOT}/ansible/group_vars/buster.yml" \
  -e "@${ROOT}/ansible/release/6.4/group_vars/all.yml"

run_runner_model_check() {
  local release_label="$1"
  shift

  echo "[validate.runtime] exercising users -> lan -> network for ${release_label} ..."
  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local \
      -e "@${ROOT}/ansible/group_vars/all.yml" "$@" \
      -e "ansible_python_interpreter_managed=${ANSIBLE_CHECK_PYTHON}" \
      --check "${ROOT}/ansible/debian/users.yml"

  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local \
      -e "@${ROOT}/ansible/group_vars/all.yml" "$@" \
      -e "ansible_python_interpreter_managed=${ANSIBLE_CHECK_PYTHON}" \
      --check "${ROOT}/ansible/debian/lan.yml"

  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local \
      -e "@${ROOT}/ansible/group_vars/all.yml" "$@" \
      -e "ansible_python_interpreter_managed=${ANSIBLE_CHECK_PYTHON}" \
      --check "${ROOT}/ansible/debian/network.yml"
}

run_runner_model_check "9.1/Trixie" \
  -e "@${ROOT}/ansible/group_vars/trixie.yml" \
  -e "@${ROOT}/ansible/release/9.1/group_vars/all.yml"
run_runner_model_check "6.4/Buster" \
  -e "@${ROOT}/ansible/group_vars/buster.yml" \
  -e "@${ROOT}/ansible/release/6.4/group_vars/all.yml"

run_proxmox_feature_check() {
  local feature_label="$1"
  shift

  echo "[validate.runtime] syntax-checking ${feature_label} ..."
  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local "$@" --syntax-check "${ROOT}/ansible/proxmox/helper/hardware.yml"

  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local "$@" --syntax-check "${ROOT}/ansible/proxmox/vlan.yml"

  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local "$@" --syntax-check "${ROOT}/ansible/proxmox/container/debian.lxc.yml"
    ansible-playbook -i localhost, -c local "$@" --syntax-check "${ROOT}/ansible/proxmox/container/debian.yml"

  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local "$@" --syntax-check "${ROOT}/ansible/proxmox/container/debian.base.yml"
  ansible-playbook -i localhost, -c local "$@" --syntax-check "${ROOT}/ansible/proxmox/container/users.yml"

  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local "$@" --syntax-check "${ROOT}/ansible/proxmox/container/network.access.yml"
}

run_proxmox_feature_check "proxmox feature playbooks" -e @${ROOT}/ansible/group_vars/proxmox.yml

echo "[validate.runtime] syntax-checking Debian Node/Codex playbooks ..."
ANSIBLE_NOCOLOR=1 \
ANSIBLE_FORCE_COLOR=0 \
  ansible-playbook -i localhost, -c local -e ansible_python_interpreter_managed=/usr/bin/python3 --syntax-check "${ROOT}/ansible/debian/node.yml"
ANSIBLE_NOCOLOR=1 \
ANSIBLE_FORCE_COLOR=0 \
  ansible-playbook -i localhost, -c local -e ansible_python_interpreter_managed=/usr/bin/python3 --syntax-check "${ROOT}/ansible/debian/cli.codex.yml"
ANSIBLE_NOCOLOR=1 \
ANSIBLE_FORCE_COLOR=0 \
  ansible-playbook -i localhost, -c local -e ansible_python_interpreter_managed=/usr/bin/python3 --syntax-check "${ROOT}/ansible/proxmox/container/node.yml"
ANSIBLE_NOCOLOR=1 \
ANSIBLE_FORCE_COLOR=0 \
  ansible-playbook -i localhost, -c local -e ansible_python_interpreter_managed=/usr/bin/python3 --syntax-check "${ROOT}/ansible/proxmox/container/codex.yml"

echo "[validate.runtime] done (check-mode only; no packages changed)."

echo "[validate.runtime] checking LXC network/SFTP policy markers..."
if ! grep -q 'FEATURE_SFTP_ENABLED' "${ROOT}/setup/lxc/network.sh"; then
  echo "[validate.runtime][error] setup/lxc/network.sh must expose FEATURE_SFTP_ENABLED"
  missing=1
fi
if ! grep -q 'proxmox_lxc_network_selector_sftp' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must normalize selector.sftp"
  missing=1
fi
if ! grep -q 'Ensure managed SFTP subsystem declaration exists' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must manage SSH SFTP subsystem declaration"
  missing=1
fi
if ! grep -q 'Detect exact SSH SFTP subsystem declaration' "${ROOT}/ansible/proxmox/container/network.access.yml"; then
  echo "[validate.runtime][error] network.access.yml must validate exact subsystem config for SFTP"
  missing=1
fi
if [[ "${missing:-0}" -ne 0 ]]; then
  echo "[validate.runtime] LXC network SFTP policy checks failed"
  exit 1
fi
echo "[validate.runtime][ok] LXC network script/playbook include SFTP markers"
