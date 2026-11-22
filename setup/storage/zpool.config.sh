#!/usr/bin/env bash
set -euo pipefail

PAGES_BASE_URL="${PAGES_BASE_URL:-https://devs-guide.github.io/proxmox}"
TMP_DIR="${PROXMOX_ZFS_TMP_DIR:-/tmp/pve-feature-zfs}"
FEATURE_PLAYBOOKS=()
FEATURE_SUPPORT_FILES=()
FEATURE_CLI_FILES=(
  "storage/zfs.pool.sh"
)

load_zfs_helper() {
  local script_dir="" repo_root="" helper=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "${script_dir}/../.." && pwd)"
    helper="${repo_root}/cli/${FEATURE_CLI_FILES[0]}"
    if [[ -r "${helper}" ]]; then
      # shellcheck source=../../cli/storage/zfs.pool.sh
      source "${helper}"
      return
    fi
  fi

  mkdir -p "${TMP_DIR}/cli/storage"
  helper="${TMP_DIR}/cli/${FEATURE_CLI_FILES[0]}"
  wget -qO "${helper}" "${PAGES_BASE_URL}/cli/${FEATURE_CLI_FILES[0]}"
  [[ -s "${helper}" ]] || {
    printf '[setup.storage.zpool.config][error] failed to fetch ZFS helper\n' >&2
    exit 1
  }
  # shellcheck source=/tmp/pve-feature-zfs/cli/storage/zfs.pool.sh
  source "${helper}"
}

load_zfs_helper
zfs_config_main "$@"
