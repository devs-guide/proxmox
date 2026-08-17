#!/usr/bin/env bash
# Canonical Proxmox VM GPU passthrough bootstrap and dispatcher.
set -euo pipefail

FEATURE_PLAYBOOKS=(
  "release/6.4/gpu.yml"
  "release/9.1/gpu.yml"
)
FEATURE_SUPPORT_FILES=(
  "proxmox/helper/vm.gpu.yml"
)
FEATURE_CLI_FILES=(
  "gpu/platform.sh"
  "gpu/inventory.sh"
  "gpu/common.sh"
  "gpu/inspect.sh"
  "gpu/apply.sh"
)

GPU_COMPONENT="setup.vm.gpu"
PAGES_BASE_URL="${PROXMOX_GPU_PAGES_BASE_URL:-https://devs-guide.github.io/proxmox}"
FEATURE_TMP_DIR="${PROXMOX_GPU_TMP_DIR:-/tmp/pve-feature-vm-gpu}"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
CLI_ROOT=""
PLAYBOOK_ROOT=""

if [[ -n "${SCRIPT_SOURCE}" && -f "${SCRIPT_SOURCE}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
fi

bootstrap.log() {
  printf '[%s] %s\n' "${GPU_COMPONENT}" "$*" >&2
}

bootstrap.error() {
  printf '[%s][error] %s\n' "${GPU_COMPONENT}" "$*" >&2
}

bootstrap.fetch() {
  local url="$1"
  local destination="$2"
  local temporary="${destination}.tmp.$$"

  mkdir -p "$(dirname "${destination}")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${temporary}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${temporary}" "${url}"
  else
    bootstrap.error "curl or wget is required to fetch published GPU dependencies"
    exit 10
  fi
  mv -f "${temporary}" "${destination}"
}

bootstrap.dependencies() {
  local requested_cli="${PROXMOX_GPU_CLI_ROOT:-}"
  local requested_playbooks="${PROXMOX_GPU_PLAYBOOK_ROOT:-}"
  local local_root=""
  local ref=""
  local missing=0

  if [[ -n "${SCRIPT_DIR}" ]]; then
    local_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
  fi

  if [[ -n "${requested_cli}" ]]; then
    CLI_ROOT="${requested_cli}"
  elif [[ -n "${local_root}" && -r "${local_root}/cli/gpu/common.sh" ]]; then
    CLI_ROOT="${local_root}/cli"
  else
    CLI_ROOT="${FEATURE_TMP_DIR}/cli"
  fi

  if [[ -n "${requested_playbooks}" ]]; then
    PLAYBOOK_ROOT="${requested_playbooks}"
  elif [[ -n "${local_root}" && -r "${local_root}/ansible/proxmox/helper/vm.gpu.yml" ]]; then
    PLAYBOOK_ROOT="${local_root}/ansible"
  else
    PLAYBOOK_ROOT="${FEATURE_TMP_DIR}/ansible"
  fi

  if [[ "${CLI_ROOT}" == "${FEATURE_TMP_DIR}/cli" ]]; then
    bootstrap.log "fetching declared GPU dependencies from ${PAGES_BASE_URL}"
    for ref in "${FEATURE_CLI_FILES[@]}"; do
      bootstrap.fetch "${PAGES_BASE_URL}/cli/${ref}" "${CLI_ROOT}/${ref}"
    done
    chmod 0644 "${CLI_ROOT}/gpu/platform.sh" "${CLI_ROOT}/gpu/inventory.sh" \
      "${CLI_ROOT}/gpu/common.sh"
    chmod 0755 "${CLI_ROOT}/gpu/inspect.sh" "${CLI_ROOT}/gpu/apply.sh"
  else
    for ref in "${FEATURE_CLI_FILES[@]}"; do
      if [[ ! -r "${CLI_ROOT}/${ref}" ]]; then
        bootstrap.error "declared CLI dependency is missing: ${CLI_ROOT}/${ref}"
        missing=1
      fi
    done
  fi

  if [[ "${PLAYBOOK_ROOT}" == "${FEATURE_TMP_DIR}/ansible" ]]; then
    for ref in "${FEATURE_PLAYBOOKS[@]}" "${FEATURE_SUPPORT_FILES[@]}"; do
      bootstrap.fetch "${PAGES_BASE_URL}/ansible/${ref}" "${PLAYBOOK_ROOT}/${ref}"
    done
  else
    for ref in "${FEATURE_PLAYBOOKS[@]}" "${FEATURE_SUPPORT_FILES[@]}"; do
      if [[ ! -r "${PLAYBOOK_ROOT}/${ref}" ]]; then
        bootstrap.error "declared Ansible dependency is missing: ${PLAYBOOK_ROOT}/${ref}"
        missing=1
      fi
    done
  fi

  ((missing == 0)) || exit 10
}

bootstrap.dependencies

export PROXMOX_GPU_CLI_ROOT="${CLI_ROOT}"
export PROXMOX_GPU_PLAYBOOK_ROOT="${PLAYBOOK_ROOT}"
exec bash "${CLI_ROOT}/gpu/apply.sh" "$@"
