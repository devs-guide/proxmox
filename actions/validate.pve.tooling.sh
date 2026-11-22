#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required=(
  setup/pve/users.sh
  setup/cli/node.sh
  setup/cli/codex.sh
  ansible/proxmox/pve/guard.yml
  ansible/proxmox/pve/users.yml
  ansible/proxmox/cli/node.yml
  ansible/proxmox/cli/codex.yml
)
for path in "${required[@]}"; do
  [[ -s "${ROOT}/${path}" ]] || { echo "[validate.pve.tooling][error] missing ${path}"; exit 1; }
done

[[ ! -e "${ROOT}/setup/cli.codex.sh" ]] || { echo '[validate.pve.tooling][error] legacy flat Codex runner remains'; exit 1; }
for entry in \
  'setup/pve/users.sh|setup/pve/users.sh|feature' \
  'setup/cli/node.sh|setup/cli/node.sh|feature' \
  'setup/cli/codex.sh|setup/cli/codex.sh|feature'; do
  grep -Fqx "${entry}" "${ROOT}/actions/pages.features.txt" || { echo "[validate.pve.tooling][error] missing manifest entry ${entry}"; exit 1; }
done
if grep -Fq 'setup.cli.codex.sh' "${ROOT}/actions/pages.features.txt"; then
  echo '[validate.pve.tooling][error] legacy flat Codex URL remains in the manifest'
  exit 1
fi

grep -Fqx 'proxmox/pve/users.yml' "${ROOT}/ansible/release/9.1/install.playbooks.txt"
grep -Fqx '# dependency: proxmox/pve/guard.yml' "${ROOT}/ansible/release/9.1/install.playbooks.txt"
grep -Fqx '# dependency: debian/users.yml' "${ROOT}/ansible/release/9.1/install.playbooks.txt"
if grep -Eq '^(debian/users[.]yml|debian/node[.]yml)$' "${ROOT}/ansible/release/9.1/install.playbooks.txt"; then
  echo '[validate.pve.tooling][error] PVE 9 playlist still directly runs Debian users or Node'
  exit 1
fi
if grep -Eq 'proxmox/pve/users[.]yml|setup/cli/(node|codex)[.]sh' "${ROOT}/ansible/release/6.4/install.playbooks.txt"; then
  echo '[validate.pve.tooling][error] PVE 6 playlist changed to the PVE 9 tooling lane'
  exit 1
fi

grep -Fq 'dependency:' "${ROOT}/bootstrap/release.common.sh"
grep -Fq 'setup/cli/node.sh' "${ROOT}/bootstrap/release.common.sh"
grep -Fq 'FEATURE_SUPPORT_FILES=("proxmox/pve/guard.yml" "debian/users.yml")' "${ROOT}/setup/pve/users.sh"
if grep -Eiq 'network[.]yml|ssh[.]yml|firewall|vlan[.]yml|bridge[.]yml|route[.]yml' "${ROOT}/setup/pve/users.sh" "${ROOT}/ansible/proxmox/pve/users.yml"; then
  echo '[validate.pve.tooling][error] PVE users path references a forbidden network/access dependency'
  exit 1
fi

for runner in setup/pve/users.sh setup/cli/node.sh setup/cli/codex.sh; do
  grep -Fq 'ensure.managed.ansible' "${ROOT}/${runner}"
  grep -Fq 'require.pve9.trixie.host' "${ROOT}/${runner}"
  bash -n "${ROOT}/${runner}"
done
grep -Fq 'PROXMOX_CLI_NODE_NVM_VERSION:-v0.40.4' "${ROOT}/setup/cli/node.sh"
grep -Fq 'PROXMOX_CLI_NODE_SHARED_NVM_DIR:-/usr/local/lib/nvm' "${ROOT}/setup/cli/node.sh"
grep -Fq 'install_policy=always' "${ROOT}/setup/cli/node.sh"
grep -Fq 'su -l "${user}"' "${ROOT}/setup/cli/node.sh"
grep -Fq 'Run setup/cli/node.sh first' "${ROOT}/setup/cli/codex.sh"
grep -Fq 'codex_install_docs_mcp: false' "${ROOT}/setup/cli/codex.sh"
grep -Fq 'su -l "${user}"' "${ROOT}/setup/cli/codex.sh"
grep -Fq 'resolved}" != /root/' "${ROOT}/setup/cli/codex.sh"

grep -Fq -- '- import_playbook: ../../debian/users.yml' "${ROOT}/ansible/proxmox/pve/users.yml"
grep -Fq -- '- import_playbook: ../../debian/node.yml' "${ROOT}/ansible/proxmox/cli/node.yml"
grep -Fq -- '- import_playbook: ../../debian/cli.codex.yml' "${ROOT}/ansible/proxmox/cli/codex.yml"
grep -Fq 'pve-manager/9[.]' "${ROOT}/ansible/proxmox/pve/guard.yml"
grep -Fq 'VERSION_CODENAME=trixie' "${ROOT}/ansible/proxmox/pve/guard.yml"
grep -Fq '/etc/ansible/proxmox/facts/pve.users.yml' "${ROOT}/ansible/proxmox/pve/users.yml"
grep -Fq '/etc/ansible/proxmox/facts/cli.node.yml' "${ROOT}/setup/cli/node.sh"
grep -Fq '/etc/ansible/proxmox/facts/cli.codex.yml' "${ROOT}/setup/cli/codex.sh"

for url in setup/pve/users.sh setup/cli/node.sh setup/cli/codex.sh; do
  grep -Fq "https://devs-guide.github.io/proxmox/${url}" "${ROOT}/docs/readme.md"
done
if grep -Fq 'https://devs-guide.github.io/proxmox/setup.cli.codex.sh' "${ROOT}/readme.md" "${ROOT}/docs/readme.md"; then
  echo '[validate.pve.tooling][error] documentation retains the legacy flat Codex URL'
  exit 1
fi

echo '[validate.pve.tooling][ok] structured PVE users, Node, and Codex contracts are complete'
"${ROOT}/tests/unit/pve_tooling_policy_test.sh"
