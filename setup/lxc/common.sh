#!/usr/bin/env bash
## Shared LXC baseline defaults for setup/lxc runners.
##
## Generic LXC common baseline (non-project):
## - root
## - app
## - agent
##
## Non-LXC/proxmox baseline remains in ansible/proxmox/common.yml
## (root/proxmox/agent) and is intentionally not pulled into this file.
PROXMOX_LXC_COMMON_BASELINE_USERS="${PROXMOX_LXC_COMMON_BASELINE_USERS:-root app agent}"
PROXMOX_LXC_CONTAINER_COMMON_SUPPORT_FILE_REL="${PROXMOX_LXC_CONTAINER_COMMON_SUPPORT_FILE_REL:-proxmox/container/common.yml}"
PROXMOX_LXC_CODEX_SANDBOX_PACKAGE="${PROXMOX_LXC_CODEX_SANDBOX_PACKAGE:-bubblewrap}"
PROXMOX_LXC_CODEX_SANDBOX_BINARY="${PROXMOX_LXC_CODEX_SANDBOX_BINARY:-bwrap}"

lxc.common.report.binary.status() {
  local label="${1:-runtime dependency}"
  local binary="${2:-}"
  local resolved_path=""

  if [[ -z "${binary}" ]]; then
    printf '[setup.lxc.common][warn] missing binary name for %s check\n' "${label}" >&2
    return 1
  fi

  if resolved_path="$(command -v "${binary}" 2>/dev/null)"; then
    printf '[setup.lxc.common] %s available: %s\n' "${label}" "${resolved_path}" >&2
    return 0
  fi

  printf '[setup.lxc.common][warn] %s missing from PATH: %s\n' "${label}" "${binary}" >&2
  return 1
}
