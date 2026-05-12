#!/usr/bin/env bash
set -euo pipefail

# Lightweight runtime sanity checklist for proxmox 9.1 (manual/offline friendly).
# Does not perform network fetches; assumes the repo is already checked out locally.
#
# Steps:
# 1) Confirm key files exist locally.
# 2) Show effective package groups with host_platform_family=proxmox.
# 3) Optional: run ansible install.packages.yml in check mode (if host is suitable).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

files=(
  "bootstrap/release.9.1.sh"
  "bootstrap/release.6.4.sh"
  "bootstrap/release.common.sh"
  "setup/vlan.sh"
  "setup/cli.codex.sh"
  "setup/lxc/debian.sh"
  "setup/lxc/samba.sh"
  "ansible/release/6.4/install.playbooks.txt"
  "ansible/release/9.1/install.playbooks.txt"
  "ansible/debian/ansible.venv.yml"
  "ansible/debian/install.packages.yml"
  "ansible/debian/codex.yml"
  "ansible/debian/netboot.yml"
  "ansible/debian/packages.yml"
  "ansible/debian/ssh.yml"
  "ansible/debian/sources.trixie.yml"
  "ansible/group_vars/proxmox.yml"
  "ansible/proxmox/helper/hardware.yml"
  "ansible/proxmox/vlan.yml"
  "ansible/proxmox/container/bootstrap/debian.create.yml"
  "ansible/proxmox/container/debian.lxc.yml"
  "ansible/proxmox/container/debian.base.yml"
  "ansible/proxmox/container/samba.file.share.yml"
  "ansible/group_vars/trixie.yml"
  "ansible/release/9.1/group_vars/all.yml"
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

echo "[validate.runtime] checking Proxmox Node/Codex runner contract..."
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/cli.codex.sh"; then
  echo "[validate.runtime][error] setup/cli.codex.sh does not define FEATURE_PLAYBOOKS array"
  exit 1
fi
if ! grep -q '"debian/node.yml"' "${ROOT}/setup/cli.codex.sh"; then
  echo "[validate.runtime][error] setup/cli.codex.sh FEATURE_PLAYBOOKS is missing debian/node.yml"
  exit 1
fi
if ! grep -q '"debian/codex.yml"' "${ROOT}/setup/cli.codex.sh"; then
  echo "[validate.runtime][error] setup/cli.codex.sh FEATURE_PLAYBOOKS is missing debian/codex.yml"
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
if ! grep -q 'MANAGED_TARGET_PYTHON_HOME=' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must define MANAGED_TARGET_PYTHON_HOME before sourcing release.common.sh"
  exit 1
fi
if ! grep -q 'ensure.container.ansible' "${ROOT}/setup/lxc/samba.sh"; then
  echo "[validate.runtime][error] setup/lxc/samba.sh must use the container-safe Ansible bootstrap helper"
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

echo "[validate.runtime] checking Proxmox Debian LXC runner contract..."
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh does not define FEATURE_PLAYBOOKS array"
  exit 1
fi
if ! grep -q '"proxmox/container/debian.lxc.yml"' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh FEATURE_PLAYBOOKS is missing proxmox/container/debian.lxc.yml"
  exit 1
fi
if ! grep -q '"proxmox/container/debian.base.yml"' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh FEATURE_PLAYBOOKS is missing proxmox/container/debian.base.yml"
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
if ! grep -q 'debian-10-standard_' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must carry the Debian 10 policy template"
  exit 1
fi
if ! grep -q 'debian-11-standard_' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must carry the Debian 11 policy template"
  exit 1
fi
if ! grep -q 'debian-12-standard_' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must carry the Debian 12 policy template"
  exit 1
fi
if ! grep -q 'debian-13-standard_' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must carry the Debian 13 policy template"
  exit 1
fi
if ! grep -q 'pveam available --section system' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must query live templates via pveam available --section system"
  exit 1
fi
if ! grep -q 'DEBIAN_LXC_TEMPLATE_BASE_URL' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must define an official Proxmox template base URL fallback"
  exit 1
fi
if ! grep -q 'official URL fallback' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must expose URL fallback policy entries when pveam hides older Debian templates"
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
if ! grep -q 'MANAGED_TARGET_PYTHON_HOME=' "${ROOT}/setup/lxc/debian.sh"; then
  echo "[validate.runtime][error] setup/lxc/debian.sh must define MANAGED_TARGET_PYTHON_HOME before sourcing release.common.sh"
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
if ! grep -q 'proxmox_vlan_data_nic_iface_manual_exists' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must avoid duplicate selected data NIC iface stanzas"
  exit 1
fi
if ! grep -q 'Baseline ifreload syntax check before VLAN write' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must run baseline ifreload syntax check before writing vmbr1"
  exit 1
fi
if ! grep -q 'Report write mode completion (staged config only)' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must report that write mode stages config without live apply"
  exit 1
fi
if ! grep -q 'Attempt runtime bridge attachment remediation when selected NIC is missing from selected bridge' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must attempt runtime attachment remediation when apply leaves the NIC detached"
  exit 1
fi
if ! grep -q 'Assert selected data NIC is attached to selected bridge after apply/remediation' "${ROOT}/ansible/proxmox/vlan.yml"; then
  echo "[validate.runtime][error] ansible/proxmox/vlan.yml must verify NIC attachment after apply/remediation"
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
if ! grep -q 'ufw allow from' "${ROOT}/ansible/proxmox/container/samba.file.share.yml"; then
  echo "[validate.runtime][error] samba.file.share.yml must configure UFW subnet rules"
  exit 1
fi
echo "[validate.runtime][ok] samba.file.share.yml includes container/Samba/SSH/firewall safeguards"

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
if ! grep -q 'template_policy:' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] ansible/group_vars/proxmox.yml must define proxmox_lxc_debian.template_policy"
  exit 1
fi
if ! grep -q 'debian-10-standard_10.7-1_amd64.tar.gz' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox template policy missing Debian 10/Buster template"
  exit 1
fi
if ! grep -q 'debian-11-standard_11.7-1_amd64.tar.zst' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox template policy missing Debian 11/Bullseye template"
  exit 1
fi
if ! grep -q 'debian-12-standard_12.12-1_amd64.tar.zst' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox template policy missing Debian 12/Bookworm template"
  exit 1
fi
if ! grep -q 'debian-13-standard_13.1-2_amd64.tar.zst' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox template policy missing Debian 13/Trixie template"
  exit 1
fi
if ! grep -q 'base_url: "https://download.proxmox.com/images/system"' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox template policy must include the official Proxmox images/system base_url"
  exit 1
fi
if ! grep -q 'fallback_download_method: "url"' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox template policy must declare URL fallback download behavior"
  exit 1
fi
if ! grep -q 'access_profile: "local_only"' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox LXC hardening defaults must include access_profile"
  exit 1
fi
if ! grep -q 'expected_dns: "10.0.0.1"' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox LXC hardening defaults must include expected_dns"
  exit 1
fi
if ! grep -q 'python3-venv' "${ROOT}/ansible/group_vars/proxmox.yml"; then
  echo "[validate.runtime][error] proxmox Debian LXC package defaults must include python3-venv"
  exit 1
fi
if ! grep -q 'ensure.container.ansible()' "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] release.common.sh must expose a container-safe Ansible bootstrap helper"
  exit 1
fi
if ! grep -q 'Using existing container system Python' "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] release.common.sh must prefer system python3 for container-local runners"
  exit 1
fi
if ! grep -q 'ensurepip --version' "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] release.common.sh must verify ensurepip availability before building the container Ansible venv"
  exit 1
fi
if ! grep -q 'Removing incomplete container Ansible venv before rebuild' "${ROOT}/bootstrap/release.common.sh"; then
  echo "[validate.runtime][error] release.common.sh must clean up incomplete container venvs after failed bootstrap attempts"
  exit 1
fi
if ! grep -q 'get_url:' "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must support official URL fallback template downloads"
  exit 1
fi
if ! grep -q "proxmox_lxc_debian_template_download_method == 'url'" "${ROOT}/ansible/proxmox/container/debian.lxc.yml"; then
  echo "[validate.runtime][error] debian.lxc.yml must branch URL fallback downloads by template.download_method"
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
if ! grep -q 'load.setup.vlan.playbooks' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh does not load setup/vlan.sh feature playbook refs"
  exit 1
fi
if ! grep -q 'load.setup.cli_codex.playbooks' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh does not load setup/cli.codex.sh feature playbook refs"
  exit 1
fi
if ! grep -q 'load.setup.samba.playbooks' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh does not load setup/lxc/samba.sh feature playbook refs"
  exit 1
fi
if ! grep -q 'load.setup.debian_lxc.playbooks' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh does not load setup/lxc/debian.sh feature playbook refs"
  exit 1
fi
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh FEATURE_PLAYBOOKS array not found for publish parsing"
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
if ! grep -q 'setup/lxc/debian.sh' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh must publish the structured Debian LXC runner path"
  exit 1
fi
if [[ -f "${ROOT}/setup/vlan.playbooks.txt" ]]; then
  echo "[validate.runtime][error] setup/vlan.playbooks.txt should not exist (array model is source-of-truth)"
  exit 1
fi
echo "[validate.runtime][ok] publish wiring follows setup/vlan.sh FEATURE_PLAYBOOKS model"

echo "[validate.runtime] checking shell syntax..."
bash -n "${ROOT}/bootstrap/release.6.4.sh"
bash -n "${ROOT}/bootstrap/release.9.1.sh"
bash -n "${ROOT}/bootstrap/release.common.sh"
bash -u -c 'log(){ :; }; log.error(){ :; }; source "${1}"; : "${ANSIBLE_CORE_VERSION:?}" "${ANSIBLE_CORE_SPEC:?}" "${MANAGED_TARGET_PYTHON_HOME:?}" "${MANAGED_TARGET_PYTHON_PATH:?}"' _ "${ROOT}/bootstrap/release.common.sh"
bash -n "${ROOT}/setup/vlan.sh"
bash -n "${ROOT}/setup/network.sh"
bash -n "${ROOT}/setup/cli.codex.sh"
bash -n "${ROOT}/setup/lxc/debian.sh"
bash -n "${ROOT}/setup/lxc/samba.sh"
echo "[validate.runtime][ok] shell syntax checks passed"

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "[validate.runtime][warn] ansible-playbook not found; skipping check-mode validation"
  exit 0
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
    -e host_platform_family=proxmox \
    -e apt_skip_cache_refresh=true \
    "$@" \
    --check \
    "${ROOT}/ansible/debian/install.packages.yml"
}

run_package_check "9.1/Trixie"
run_package_check "6.4/Buster" -e @${ROOT}/ansible/group_vars/buster.yml -e @${ROOT}/ansible/release/6.4/group_vars/all.yml

run_runner_model_check() {
  local release_label="$1"
  shift

  echo "[validate.runtime] exercising users -> lan -> network for ${release_label} ..."
  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local "$@" --check "${ROOT}/ansible/debian/users.yml"

  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local "$@" --check "${ROOT}/ansible/debian/lan.yml"

  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local "$@" --check "${ROOT}/ansible/debian/network.yml"
}

run_runner_model_check "9.1/Trixie"
run_runner_model_check "6.4/Buster" -e @${ROOT}/ansible/group_vars/buster.yml -e @${ROOT}/ansible/release/6.4/group_vars/all.yml

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

  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    ansible-playbook -i localhost, -c local "$@" --syntax-check "${ROOT}/ansible/proxmox/container/debian.base.yml"
}

run_proxmox_feature_check "proxmox feature playbooks" -e @${ROOT}/ansible/group_vars/proxmox.yml

echo "[validate.runtime] syntax-checking Debian Node/Codex playbooks ..."
ANSIBLE_NOCOLOR=1 \
ANSIBLE_FORCE_COLOR=0 \
  ansible-playbook -i localhost, -c local -e ansible_python_interpreter_managed=/usr/bin/python3 --syntax-check "${ROOT}/ansible/debian/node.yml"
ANSIBLE_NOCOLOR=1 \
ANSIBLE_FORCE_COLOR=0 \
  ansible-playbook -i localhost, -c local -e ansible_python_interpreter_managed=/usr/bin/python3 --syntax-check "${ROOT}/ansible/debian/codex.yml"

echo "[validate.runtime] done (check-mode only; no packages changed)."
