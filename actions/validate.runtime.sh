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
  "ansible/release/6.4/install.playbooks.txt"
  "ansible/release/9.1/install.playbooks.txt"
  "ansible/debian/ansible.venv.yml"
  "ansible/debian/install.packages.yml"
  "ansible/debian/packages.yml"
  "ansible/debian/sources.trixie.yml"
  "ansible/group_vars/proxmox.yml"
  "ansible/proxmox/helper/hardware.yml"
  "ansible/proxmox/vlan.yml"
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
echo "[validate.runtime][ok] ansible/proxmox/vlan.yml includes selection/oob/rollback safeguards"

echo "[validate.runtime] checking hardware helper regression guards..."
if grep -q "regex_search(' master (\\\\S+)', '\\\\1')" "${ROOT}/ansible/proxmox/helper/hardware.yml"; then
  echo "[validate.runtime][error] helper/hardware.yml uses unsafe regex_search capture for bridge_member"
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

echo "[validate.runtime] checking publish wiring contract..."
if grep -qE '(^|[[:space:]])proxmox/' "${ROOT}/ansible/debian/install.playbooks.txt"; then
  echo "[validate.runtime][error] ansible/debian/install.playbooks.txt must remain Debian-only (found proxmox entry)"
  exit 1
fi
if ! grep -q 'load.setup.vlan.playbooks' "${ROOT}/actions/www.pages.sh"; then
  echo "[validate.runtime][error] actions/www.pages.sh does not load setup/vlan.sh feature playbook refs"
  exit 1
fi
if ! grep -q 'FEATURE_PLAYBOOKS=(' "${ROOT}/setup/vlan.sh"; then
  echo "[validate.runtime][error] setup/vlan.sh FEATURE_PLAYBOOKS array not found for publish parsing"
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
bash -n "${ROOT}/setup/vlan.sh"
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
}

run_proxmox_feature_check "proxmox feature playbooks" -e @${ROOT}/ansible/group_vars/proxmox.yml

echo "[validate.runtime] done (check-mode only; no packages changed)."
