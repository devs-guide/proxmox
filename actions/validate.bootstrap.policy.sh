#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARS="${ROOT}/ansible/group_vars/all.yml"
USERS="${ROOT}/ansible/debian/users.yml"
NETWORK="${ROOT}/ansible/debian/network.yml"
COMMON="${ROOT}/bootstrap/release.common.sh"
PVE9="${ROOT}/bootstrap/release.9.1.sh"

fail() {
  printf '[validate.bootstrap.policy][error] %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '[validate.bootstrap.policy][ok] %s\n' "$*"
}

for file in "${COMMON}" "${PVE9}"; do
  bash -n "${file}" || fail "Bash syntax failed: ${file#${ROOT}/}"
done

for marker in \
  'bootstrap_default_password_mode: "username"' \
  'bootstrap_default_user_update_password: "always"' \
  '  - name: app' \
  '  - name: agent' \
  '  - name: proxmox' \
  '  - name: root' \
  '  manage_firewall: false' \
  '  allow_rdp: false' \
  '  ipv6: true'; do
  grep -Fq "${marker}" "${VARS}" || fail "static defaults are missing: ${marker}"
done
user_block="$(sed -n '/^user_defs:/,/^bootstrap_default_password_mode:/p' "${VARS}")"
if grep -Eq 'password:|password_lock:' <<< "${user_block}"; then
  fail "static user definitions bypass the configured password mode"
fi
ok "static defaults preserve username:username while requiring explicit firewall scope"

for marker in \
  "bootstrap_password_mode_effective == 'username'" \
  "item.name | password_hash(default_password_hash_algo)" \
  "if bootstrap_password_mode_effective == 'username'" \
  "bootstrap_default_user_update_password" \
  "bootstrap_password_mode_effective in ['username', 'preserve', 'locked']"; do
  grep -Fq "${marker}" "${USERS}" || fail "users policy is missing: ${marker}"
done
if grep -Fq "item.password | default(item.name" "${USERS}"; then
  fail "users policy bypasses the explicit password-mode switch"
fi
ok "user playbook makes the default and override modes explicit"

for marker in \
  "network_manage_firewall" \
  "network_config.allow_rdp | bool" \
  "Remove legacy RDP allow rules when RDP is disabled" \
  "IPV6={{ 'yes'" \
  'validate: "/usr/sbin/sshd -t -f %s"'; do
  grep -Fq "${marker}" "${NETWORK}" || fail "network policy is missing: ${marker}"
done
if grep -Fq "['10.0.0.0/24'] if" "${NETWORK}"; then
  fail "network policy still silently substitutes the legacy management subnet"
fi
ok "firewall, RDP, IPv6, and SSH reload policy fail closed"

for marker in \
  "PROXMOX_BOOTSTRAP_PASSWORD_MODE" \
  "PROXMOX_MANAGEMENT_SUBNETS" \
  "PROXMOX_MANAGE_HOST_FIREWALL" \
  "PROXMOX_ALLOW_RDP" \
  "BOOTSTRAP COMPLETE"; do
  grep -Fq "${marker}" "${COMMON}" || fail "bootstrap runtime is missing: ${marker}"
done
grep -Fq "bootstrap.final.summary" "${PVE9}" \
  || fail "PVE 9 runner does not emit the final summary"
ok "streamed overrides and an unambiguous completion marker are present"

printf '[validate.bootstrap.policy] all bootstrap policy contracts passed\n'
