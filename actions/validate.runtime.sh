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
  "bootstrap/release.common.sh"
  "ansible/release/9.1/install.playbooks.txt"
  "ansible/debian/ansible.venv.yml"
  "ansible/debian/install.packages.yml"
  "ansible/debian/packages.yml"
  "ansible/debian/sources.trixie.yml"
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

echo "[validate.runtime] showing effective package groups (host_platform_family=proxmox) ..."
ANSIBLE_NOCOLOR=1 \
ANSIBLE_FORCE_COLOR=0 \
  ansible-playbook \
  -i localhost, \
  -c local \
  -e host_platform_family=proxmox \
  -e apt_skip_cache_refresh=true \
  --check \
  "${ROOT}/ansible/debian/install.packages.yml"

echo "[validate.runtime] done (check-mode only; no packages changed)."
