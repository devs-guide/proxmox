#!/usr/bin/env bash
# Canonical remote Proxmox VM restore feature runner.
set -euo pipefail

FEATURE_PLAYBOOKS=(
  "proxmox/helper/vm.restore.yml"
)
FEATURE_CLI_FILES=(
  "lib/restore.common.sh"
  "ssh/sync.sh"
  "storage/temp.sh"
  "rsync/fetch.sh"
)

PAGES_BASE_URL="${PROXMOX_RESTORE_PAGES_BASE_URL:-https://devs-guide.github.io/proxmox}"
FEATURE_TMP_DIR="${PROXMOX_RESTORE_TMP_DIR:-/tmp/pve-feature-vm-restore}"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
CLI_ROOT=""
PLAYBOOK_PATH=""

if [[ -n "${SCRIPT_SOURCE}" && -f "${SCRIPT_SOURCE}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
fi

bootstrap.log() {
  printf '[setup.vm.restore] %s\n' "$*" >&2
}

bootstrap.error() {
  printf '[setup.vm.restore][error] %s\n' "$*" >&2
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
    bootstrap.error "curl or wget is required to fetch published restore helpers"
    exit 10
  fi
  mv -f "${temporary}" "${destination}"
}

bootstrap.feature_files() {
  local requested_root="${PROXMOX_RESTORE_CLI_ROOT:-}"
  local local_root=""
  local ref=""
  local missing=0

  if [[ -n "${SCRIPT_DIR}" ]]; then
    local_root="${SCRIPT_DIR}/../../cli"
  fi

  if [[ -n "${requested_root}" ]]; then
    CLI_ROOT="${requested_root}"
  elif [[ -n "${local_root}" && -r "${local_root}/lib/restore.common.sh" ]]; then
    CLI_ROOT="$(cd "${local_root}" && pwd)"
  else
    CLI_ROOT="${FEATURE_TMP_DIR}/cli"
  fi

  if [[ "${CLI_ROOT}" == "${FEATURE_TMP_DIR}/cli" ]]; then
    bootstrap.log "fetching declared CLI dependencies from ${PAGES_BASE_URL}/cli"
    for ref in "${FEATURE_CLI_FILES[@]}"; do
      bootstrap.fetch "${PAGES_BASE_URL}/cli/${ref}" "${CLI_ROOT}/${ref}"
    done
    chmod 0644 "${CLI_ROOT}/lib/restore.common.sh"
    chmod 0755 "${CLI_ROOT}/ssh/sync.sh" "${CLI_ROOT}/storage/temp.sh" "${CLI_ROOT}/rsync/fetch.sh"
    PLAYBOOK_PATH="${FEATURE_TMP_DIR}/ansible/${FEATURE_PLAYBOOKS[0]}"
    bootstrap.fetch "${PAGES_BASE_URL}/ansible/${FEATURE_PLAYBOOKS[0]}" "${PLAYBOOK_PATH}"
  else
    for ref in "${FEATURE_CLI_FILES[@]}"; do
      if [[ ! -r "${CLI_ROOT}/${ref}" ]]; then
        bootstrap.error "declared CLI dependency is missing: ${CLI_ROOT}/${ref}"
        missing=1
      fi
    done
    ((missing == 0)) || exit 10
    PLAYBOOK_PATH="${SCRIPT_DIR}/../../ansible/${FEATURE_PLAYBOOKS[0]}"
    [[ -r "${PLAYBOOK_PATH}" ]] || {
      bootstrap.error "declared dependency playbook is missing: ${PLAYBOOK_PATH}"
      exit 10
    }
  fi
}

bootstrap.feature_files

RESTORE_COMPONENT="setup.vm.restore"
# shellcheck source=../../cli/lib/restore.common.sh
source "${CLI_ROOT}/lib/restore.common.sh"

SSH_SYNC="${CLI_ROOT}/ssh/sync.sh"
STORAGE_TEMP="${CLI_ROOT}/storage/temp.sh"
RSYNC_FETCH="${CLI_ROOT}/rsync/fetch.sh"

ACTION="all"
VM_ID=""
SOURCE_VM_ID=""
REMOTE_HOST=""
REMOTE_USER="root"
REMOTE_PORT="22"
REMOTE_PATH=""
IDENTITY="/root/.ssh/proxmox-restore-ed25519"
KNOWN_HOSTS="/root/.ssh/known_hosts"
HOST_KEY_FINGERPRINT=""
CONNECT_TIMEOUT="10"
ARCHIVE=""
STAGE_STORAGE="local-lvm"
TARGET_STORAGE="local-lvm"
STAGE_SIZE="auto"
MOUNT_ROOT="/mnt/pve-restore"
MAX_THIN_DATA_PERCENT="85"
MAX_THIN_METADATA_PERCENT="75"
CAPACITY_OVERRIDE=0
REPLACE_EXISTING=0
UNIQUE=0
START_VM=0
CLEANUP_POLICY="success"
RSYNC_BWLIMIT_KBPS=""
RESTORE_BWLIMIT_KBPS=""
YES=0
DRY_RUN=0
OUTPUT="human"

CURRENT_PHASE="arguments"
ACTIVE_MANIFEST=""
REMOTE_BYTES=""
REMOTE_SHA256=""
REMOTE_BASENAME=""
LOCAL_BYTES=""
LOCAL_SHA256=""
VMA_DEVICE_BYTES="0"
VMA_SPARSE_BYTES="0"
VMA_STREAM_BYTES="0"
VMA_ESTIMATED_BYTES="0"
RESTORE_REPLACEMENT=0

usage() {
  cat <<'EOF'
Usage: setup/vm/restore.sh --vm ID --action ACTION [options]

Fetch a remote QEMU VMA backup to a temporary filesystem-backed thin LV,
verify it completely, restore it with qmrestore, and safely remove the stage.

Actions:
  preflight   Read-only local, storage, SSH, and optional remote-file checks
  transfer    Create/resume the stage and resumably transfer the archive
  verify      Verify one local --archive without mutating VM state
  restore     Verify and restore one local --archive
  cleanup     Remove only the manifest-owned staging LV
  all         Run preflight, transfer, verify, restore, cleanup (default)

Core flags:
  --vm ID                            Required target VM ID
  --source-vm ID                     Optional expected source VM ID
  --remote-host HOST                 Required for transfer/all
  --remote-path PATH                 Required for transfer/all
  --archive PATH                     Required for verify/restore
  --action preflight|transfer|verify|restore|cleanup|all

Connection flags:
  --remote-user USER                 Default: root
  --remote-port PORT                 Default: 22
  --identity PATH                    Default: /root/.ssh/proxmox-restore-ed25519
  --known-hosts PATH                 Default: /root/.ssh/known_hosts
  --host-key-fingerprint SHA256:...  Optional pin used by cli/ssh/sync.sh setup
  --connect-timeout SECONDS          Default: 10

Storage and safety flags:
  --stage-storage STORAGE            Default: local-lvm
  --target-storage STORAGE           Default: local-lvm
  --stage-size auto|SIZE             Default: auto
  --mount-root PATH                  Default: /mnt/pve-restore
  --max-thin-data-percent PERCENT    Default: 85
  --max-thin-metadata-percent PERCENT Default: 75
  --capacity-override                Requires explicit confirmation
  --replace-existing                 Replace only a stopped local non-HA VM
  --unique                           Pass --unique 1 to qmrestore
  --start                            Start only after successful cleanup
  --cleanup success|never            Default: success
  --rsync-bwlimit-kbps RATE
  --restore-bwlimit-kbps RATE
  --yes                              Confirms an already-requested destructive gate
  --dry-run                          Inspect and print; do not mutate
  --output human|path|bytes|sha256|json
  --help

Passwordless SSH is intentionally separate:
  cli/ssh/sync.sh --action setup --remote-host 10.0.0.11
  cli/ssh/sync.sh --action setup --remote-host 10.0.0.11 \
    --key-rotation --yes

Complete restore example:
  setup/vm/restore.sh --action all --vm 201 --source-vm 200 \
    --remote-host 10.0.0.11 \
    --remote-path /media/backup/vzdump-qemu-200-date.vma.zst \
    --stage-storage local-lvm --target-storage local-lvm --unique

Published runner:
  wget -qO /tmp/proxmox-vm-restore.sh \
    https://devs-guide.github.io/proxmox/setup/vm/restore.sh
  chmod 0755 /tmp/proxmox-vm-restore.sh
  /tmp/proxmox-vm-restore.sh --action preflight --vm 200
EOF
}

while (($#)); do
  case "$1" in
    --action) restore.require_flag_value "$1" "${2-}"; ACTION="$2"; shift 2 ;;
    --vm) restore.require_flag_value "$1" "${2-}"; VM_ID="$2"; shift 2 ;;
    --source-vm) restore.require_flag_value "$1" "${2-}"; SOURCE_VM_ID="$2"; shift 2 ;;
    --remote-host) restore.require_flag_value "$1" "${2-}"; REMOTE_HOST="$2"; shift 2 ;;
    --remote-user) restore.require_flag_value "$1" "${2-}"; REMOTE_USER="$2"; shift 2 ;;
    --remote-port) restore.require_flag_value "$1" "${2-}"; REMOTE_PORT="$2"; shift 2 ;;
    --remote-path) restore.require_flag_value "$1" "${2-}"; REMOTE_PATH="$2"; shift 2 ;;
    --identity) restore.require_flag_value "$1" "${2-}"; IDENTITY="$2"; shift 2 ;;
    --known-hosts) restore.require_flag_value "$1" "${2-}"; KNOWN_HOSTS="$2"; shift 2 ;;
    --host-key-fingerprint) restore.require_flag_value "$1" "${2-}"; HOST_KEY_FINGERPRINT="$2"; shift 2 ;;
    --connect-timeout) restore.require_flag_value "$1" "${2-}"; CONNECT_TIMEOUT="$2"; shift 2 ;;
    --archive) restore.require_flag_value "$1" "${2-}"; ARCHIVE="$2"; shift 2 ;;
    --stage-storage) restore.require_flag_value "$1" "${2-}"; STAGE_STORAGE="$2"; shift 2 ;;
    --target-storage) restore.require_flag_value "$1" "${2-}"; TARGET_STORAGE="$2"; shift 2 ;;
    --stage-size) restore.require_flag_value "$1" "${2-}"; STAGE_SIZE="$2"; shift 2 ;;
    --mount-root) restore.require_flag_value "$1" "${2-}"; MOUNT_ROOT="$2"; shift 2 ;;
    --max-thin-data-percent) restore.require_flag_value "$1" "${2-}"; MAX_THIN_DATA_PERCENT="$2"; shift 2 ;;
    --max-thin-metadata-percent) restore.require_flag_value "$1" "${2-}"; MAX_THIN_METADATA_PERCENT="$2"; shift 2 ;;
    --capacity-override) CAPACITY_OVERRIDE=1; shift ;;
    --replace-existing) REPLACE_EXISTING=1; shift ;;
    --unique) UNIQUE=1; shift ;;
    --start) START_VM=1; shift ;;
    --cleanup) restore.require_flag_value "$1" "${2-}"; CLEANUP_POLICY="$2"; shift 2 ;;
    --rsync-bwlimit-kbps) restore.require_flag_value "$1" "${2-}"; RSYNC_BWLIMIT_KBPS="$2"; shift 2 ;;
    --restore-bwlimit-kbps) restore.require_flag_value "$1" "${2-}"; RESTORE_BWLIMIT_KBPS="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --output) restore.require_flag_value "$1" "${2-}"; OUTPUT="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --*) restore.die "${RESTORE_EXIT_USAGE}" "unknown flag: $1" ;;
    *) restore.die "${RESTORE_EXIT_USAGE}" "positional arguments are not supported: $1" ;;
  esac
done

validate_arguments() {
  case "${ACTION}" in
    preflight|transfer|verify|restore|cleanup|all) ;;
    *) restore.die "${RESTORE_EXIT_USAGE}" "unsupported --action: ${ACTION}" ;;
  esac
  [[ -n "${VM_ID}" ]] || restore.die "${RESTORE_EXIT_USAGE}" "--vm is required"
  restore.validate_vm_id "${VM_ID}"
  [[ -z "${SOURCE_VM_ID}" ]] || restore.validate_vm_id "${SOURCE_VM_ID}"
  restore.validate_port "${REMOTE_PORT}"
  restore.validate_positive_uint "--connect-timeout" "${CONNECT_TIMEOUT}"
  restore.validate_storage_id "${STAGE_STORAGE}"
  restore.validate_storage_id "${TARGET_STORAGE}"
  restore.validate_percent "--max-thin-data-percent" "${MAX_THIN_DATA_PERCENT}"
  restore.validate_percent "--max-thin-metadata-percent" "${MAX_THIN_METADATA_PERCENT}"
  [[ -z "${RSYNC_BWLIMIT_KBPS}" ]] || restore.validate_positive_uint "--rsync-bwlimit-kbps" "${RSYNC_BWLIMIT_KBPS}"
  [[ -z "${RESTORE_BWLIMIT_KBPS}" ]] || restore.validate_positive_uint "--restore-bwlimit-kbps" "${RESTORE_BWLIMIT_KBPS}"
  [[ "${CLEANUP_POLICY}" == success || "${CLEANUP_POLICY}" == never ]] || restore.die "${RESTORE_EXIT_USAGE}" "--cleanup must be success or never"
  [[ -z "${HOST_KEY_FINGERPRINT}" || "${HOST_KEY_FINGERPRINT}" == SHA256:* ]] || \
    restore.die "${RESTORE_EXIT_USAGE}" "--host-key-fingerprint must start with SHA256:"
  [[ "${MOUNT_ROOT}" == /* && "${MOUNT_ROOT}" != *'/../'* && "${MOUNT_ROOT}" != */.. ]] || \
    restore.die "${RESTORE_EXIT_USAGE}" "--mount-root must be an absolute normalized path"
  [[ "${IDENTITY}" == /* ]] || restore.die "${RESTORE_EXIT_USAGE}" "--identity must be absolute"
  [[ "${KNOWN_HOSTS}" == /* ]] || restore.die "${RESTORE_EXIT_USAGE}" "--known-hosts must be absolute"
  [[ "${STAGE_SIZE}" == auto ]] || restore.parse_size_bytes "${STAGE_SIZE}" >/dev/null
  if [[ -n "${REMOTE_HOST}" ]]; then
    restore.validate_host "${REMOTE_HOST}"
    restore.validate_remote_user "${REMOTE_USER}"
  fi
  if [[ "${ACTION}" == transfer || "${ACTION}" == all ]]; then
    [[ -n "${REMOTE_HOST}" ]] || restore.die "${RESTORE_EXIT_USAGE}" "--remote-host is required for ${ACTION}"
    [[ -n "${REMOTE_PATH}" ]] || restore.die "${RESTORE_EXIT_USAGE}" "--remote-path is required for ${ACTION}"
  fi
  if [[ "${ACTION}" == verify || "${ACTION}" == restore ]]; then
    [[ -n "${ARCHIVE}" ]] || restore.die "${RESTORE_EXIT_USAGE}" "--archive is required for ${ACTION}"
  fi
  if [[ -n "${REMOTE_PATH}" && -z "${REMOTE_HOST}" ]]; then
    restore.die "${RESTORE_EXIT_USAGE}" "--remote-path requires --remote-host"
  fi
  if [[ -n "${REMOTE_PATH}" ]]; then
    [[ "${REMOTE_PATH}" == /* ]] || restore.die "${RESTORE_EXIT_USAGE}" "--remote-path must be absolute"
    restore.validate_archive_name "${REMOTE_PATH}"
  fi
  if [[ -n "${ARCHIVE}" ]]; then
    restore.validate_archive_name "${ARCHIVE}"
  fi
  if ((START_VM)) && [[ "${CLEANUP_POLICY}" == never && ( "${ACTION}" == all || "${ACTION}" == restore ) ]]; then
    restore.die "${RESTORE_EXIT_USAGE}" "--start cannot be combined with --cleanup never"
  fi
  case "${ACTION}" in
    preflight) restore.validate_output "${OUTPUT}" human json ;;
    cleanup) restore.validate_output "${OUTPUT}" human path json ;;
    *) restore.validate_output "${OUTPUT}" human path bytes sha256 json ;;
  esac
}

validate_arguments

on_exit() {
  local exit_code="$?"
  trap - EXIT
  if ((exit_code != 0)); then
    if [[ "${DRY_RUN}" != "1" && -n "${ACTIVE_MANIFEST}" && -f "${ACTIVE_MANIFEST}" ]]; then
      restore.manifest_put "${ACTIVE_MANIFEST}" phase "failed:${CURRENT_PHASE}" 2>/dev/null || true
      restore.manifest_put "${ACTIVE_MANIFEST}" resume_action "${ACTION}" 2>/dev/null || true
    fi
    restore.error "phase ${CURRENT_PHASE} failed with exit ${exit_code}; any verified staging archive was retained"
  fi
  exit "${exit_code}"
}
trap on_exit EXIT

connection_args() {
  local -n output_args="$1"
  output_args=(
    --remote-host "${REMOTE_HOST}"
    --remote-user "${REMOTE_USER}"
    --remote-port "${REMOTE_PORT}"
    --identity "${IDENTITY}"
    --known-hosts "${KNOWN_HOSTS}"
    --connect-timeout "${CONNECT_TIMEOUT}"
  )
  if [[ -n "${HOST_KEY_FINGERPRINT}" ]]; then
    output_args+=(--host-key-fingerprint "${HOST_KEY_FINGERPRINT}")
  fi
  return 0
}

storage_args() {
  local -n output_args="$1"
  output_args=(
    --vm "${VM_ID}"
    --storage "${STAGE_STORAGE}"
    --mount-root "${MOUNT_ROOT}"
    --max-thin-data-percent "${MAX_THIN_DATA_PERCENT}"
    --max-thin-metadata-percent "${MAX_THIN_METADATA_PERCENT}"
  )
  if [[ -n "${SOURCE_VM_ID}" ]]; then
    output_args+=(--source-vm "${SOURCE_VM_ID}")
  fi
  if ((DRY_RUN)); then
    output_args+=(--dry-run)
  fi
  return 0
}

local_preflight() {
  CURRENT_PHASE="preflight"
  restore.log "preflight: validating the local Proxmox node"
  restore.require_proxmox
  restore.log "preflight: checking required restore commands"
  restore.require_commands "${RESTORE_EXIT_PREFLIGHT}" \
    qm qmrestore pvesm lvs vgs lvcreate lvremove mkfs.ext4 mount umount findmnt flock \
    ssh rsync sha256sum zstd vma lsblk stat awk grep sed tee sync ha-manager jq
  restore.log "preflight: acquiring the restore lock for VM ${VM_ID}"
  restore.acquire_lock "${VM_ID}"
  restore.log "preflight: checking stage storage ${STAGE_STORAGE}"
  pvesm status --storage "${STAGE_STORAGE}" 2>/dev/null | awk -v storage="${STAGE_STORAGE}" '$1 == storage && $3 == "active" {found=1} END {exit !found}' || \
    restore.die "${RESTORE_EXIT_PREFLIGHT}" "stage storage is unavailable: ${STAGE_STORAGE}"
  restore.log "preflight: checking target storage ${TARGET_STORAGE}"
  pvesm status --storage "${TARGET_STORAGE}" 2>/dev/null | awk -v storage="${TARGET_STORAGE}" '$1 == storage && $3 == "active" {found=1} END {exit !found}' || \
    restore.die "${RESTORE_EXIT_PREFLIGHT}" "target storage is unavailable: ${TARGET_STORAGE}"
  local -a stage_args=()
  storage_args stage_args
  restore.log "preflight: inspecting temporary-stage state for VM ${VM_ID}"
  if ! "${STORAGE_TEMP}" --action status "${stage_args[@]}" --output json >/dev/null; then
    restore.die "${RESTORE_EXIT_PREFLIGHT}" "stage-storage inspection failed"
  fi
  if [[ -n "${REMOTE_HOST}" ]]; then
    local -a ssh_args=()
    connection_args ssh_args
    restore.log "preflight: checking passwordless SSH access to ${REMOTE_USER}@${REMOTE_HOST}"
    "${SSH_SYNC}" --action check "${ssh_args[@]}" --output human
  fi
  restore.log "preflight passed for target VM ${VM_ID}; dependency playbook: ${PLAYBOOK_PATH}"
}

inspect_remote_archive() {
  CURRENT_PHASE="remote-inspection"
  local -a ssh_args=()
  local metadata
  connection_args ssh_args
  metadata="$("${RSYNC_FETCH}" --action inspect "${ssh_args[@]}" --remote-path "${REMOTE_PATH}" --output json)"
  restore.json_require "${metadata}" '
    type == "object"
    and (.bytes | type == "number" and . > 0 and floor == .)
    and (.sha256 | type == "string" and test("^[0-9a-fA-F]{64}$"))
    and (.basename | type == "string" and length > 0)
  ' "remote archive helper" "${RESTORE_EXIT_TRANSFER}"
  REMOTE_BYTES="$(restore.json_get "${metadata}" '.bytes | tostring' "remote archive bytes" "${RESTORE_EXIT_TRANSFER}")"
  REMOTE_SHA256="$(restore.json_get "${metadata}" '.sha256' "remote archive SHA-256" "${RESTORE_EXIT_TRANSFER}")"
  REMOTE_BASENAME="$(restore.json_get "${metadata}" '.basename' "remote archive basename" "${RESTORE_EXIT_TRANSFER}")"
  resolve_source_vm "${REMOTE_BASENAME}"
}

resolve_source_vm() {
  local path="$1"
  local derived=""
  derived="$(restore.archive_source_vm "${path}" 2>/dev/null || true)"
  [[ -n "${derived}" ]] || restore.die "${RESTORE_EXIT_INTEGRITY}" "could not derive source VM ID from archive name: ${path##*/}"
  if [[ -n "${SOURCE_VM_ID}" && "${SOURCE_VM_ID}" != "${derived}" ]]; then
    restore.die "${RESTORE_EXIT_INTEGRITY}" "archive source VM ${derived} does not match --source-vm ${SOURCE_VM_ID}"
  fi
  SOURCE_VM_ID="${SOURCE_VM_ID:-${derived}}"
}

perform_transfer() {
  CURRENT_PHASE="staging"
  inspect_remote_archive
  local -a stage_args=()
  local -a ssh_args=()
  local -a create_args=()
  storage_args stage_args
  create_args=(
    "${stage_args[@]}"
    --source-bytes "${REMOTE_BYTES}"
    --stage-size "${STAGE_SIZE}"
    --remote-host "${REMOTE_HOST}"
    --remote-user "${REMOTE_USER}"
    --remote-path "${REMOTE_PATH}"
    --remote-sha256 "${REMOTE_SHA256}"
    --archive-basename "${REMOTE_BASENAME}"
  )
  ((CAPACITY_OVERRIDE)) && create_args+=(--capacity-override)
  ((YES)) && create_args+=(--yes)
  local stage_dir
  stage_dir="$("${STORAGE_TEMP}" --action create "${create_args[@]}" --output path)"
  [[ -n "${stage_dir}" ]] || restore.die "${RESTORE_EXIT_STORAGE}" "storage helper did not return a stage path"
  ACTIVE_MANIFEST="${stage_dir}/.proxmox-restore.tsv"

  CURRENT_PHASE="transfer"
  connection_args ssh_args
  local -a fetch_args=(
    --action transfer
    "${ssh_args[@]}"
    --remote-path "${REMOTE_PATH}"
    --destination-dir "${stage_dir}"
    --output path
  )
  [[ -z "${RSYNC_BWLIMIT_KBPS}" ]] || fetch_args+=(--rsync-bwlimit-kbps "${RSYNC_BWLIMIT_KBPS}")
  ((DRY_RUN)) && fetch_args+=(--dry-run)
  ARCHIVE="$("${RSYNC_FETCH}" "${fetch_args[@]}")"
  [[ -n "${ARCHIVE}" ]] || restore.die "${RESTORE_EXIT_TRANSFER}" "transfer helper did not return an archive path"
  if ((DRY_RUN == 0)); then
    restore.manifest_put "${ACTIVE_MANIFEST}" archive "${ARCHIVE}"
    restore.manifest_put "${ACTIVE_MANIFEST}" local_bytes "${REMOTE_BYTES}"
    restore.manifest_put "${ACTIVE_MANIFEST}" local_sha256 "${REMOTE_SHA256}"
    restore.manifest_put "${ACTIVE_MANIFEST}" phase transferred
  fi
}

verify_archive() {
  CURRENT_PHASE="verify"
  restore.validate_archive_name "${ARCHIVE}"
  [[ -f "${ARCHIVE}" && ! -L "${ARCHIVE}" ]] || \
    restore.die "${RESTORE_EXIT_INTEGRITY}" "archive must be a local regular non-symlink file: ${ARCHIVE}"
  resolve_source_vm "${ARCHIVE}"
  LOCAL_BYTES="$(stat -Lc %s -- "${ARCHIVE}")"
  LOCAL_SHA256="$(sha256sum -- "${ARCHIVE}")"
  LOCAL_SHA256="${LOCAL_SHA256%% *}"
  [[ "${LOCAL_BYTES}" =~ ^[0-9]+$ && "${LOCAL_BYTES}" -gt 0 ]] || restore.die "${RESTORE_EXIT_INTEGRITY}" "local archive has an invalid size"

  local archive_dir manifest expected_bytes expected_sha verify_log verify_rc=0
  archive_dir="$(cd "$(dirname "${ARCHIVE}")" && pwd)"
  manifest="${archive_dir}/.proxmox-restore.tsv"
  if [[ -f "${manifest}" && ! -L "${manifest}" ]]; then
    ACTIVE_MANIFEST="${manifest}"
    restore.manifest_require "${manifest}" target_vm "${VM_ID}"
    expected_bytes="$(restore.manifest_get "${manifest}" source_bytes 2>/dev/null || true)"
    expected_sha="$(restore.manifest_get "${manifest}" remote_sha256 2>/dev/null || true)"
    [[ -z "${expected_bytes}" || "${LOCAL_BYTES}" == "${expected_bytes}" ]] || \
      restore.die "${RESTORE_EXIT_INTEGRITY}" "local byte count does not match the stage manifest"
    [[ -z "${expected_sha}" || "${LOCAL_SHA256}" == "${expected_sha}" ]] || \
      restore.die "${RESTORE_EXIT_INTEGRITY}" "local SHA-256 does not match the stage manifest"
  fi

  verify_log="$(mktemp)"
  restore.log "verifying VMA stream; this reads the complete archive"
  if [[ "${ARCHIVE}" == *.vma.zst ]]; then
    if zstd --no-progress --decompress --stdout "${ARCHIVE}" | vma verify -v /dev/stdin 2>&1 | tee "${verify_log}" >&2; then
      verify_rc=0
    else
      verify_rc=$?
    fi
  else
    if vma verify -v "${ARCHIVE}" 2>&1 | tee "${verify_log}" >&2; then
      verify_rc=0
    else
      verify_rc=$?
    fi
  fi
  if ((verify_rc != 0)); then
    rm -f "${verify_log}"
    restore.die "${RESTORE_EXIT_INTEGRITY}" "zstd/VMA verification failed"
  fi
  grep -q 'qemu-server.conf' "${verify_log}" || {
    rm -f "${verify_log}"
    restore.die "${RESTORE_EXIT_INTEGRITY}" "verified VMA did not contain qemu-server.conf"
  }
  VMA_DEVICE_BYTES="$(awk '/^DEV:/ {for (i=1; i<=NF; i++) if ($i == "size:") total += $(i+1)} END {printf "%.0f", total+0}' "${verify_log}")"
  VMA_STREAM_BYTES="$(awk '/total bytes read/ {for (i=1; i<=NF; i++) {value=$i; gsub(/,/, "", value); if (value ~ /^[0-9]+$/) {print value; exit}}}' "${verify_log}")"
  VMA_SPARSE_BYTES="$(awk 'tolower($0) ~ /sparse|zero/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) value=$i} END {printf "%.0f", value+0}' "${verify_log}")"
  rm -f "${verify_log}"
  ((VMA_DEVICE_BYTES > 0)) || restore.die "${RESTORE_EXIT_INTEGRITY}" "could not derive VMA device allocation from verification output"
  VMA_STREAM_BYTES="${VMA_STREAM_BYTES:-${VMA_DEVICE_BYTES}}"
  if ((VMA_SPARSE_BYTES > 0 && VMA_SPARSE_BYTES < VMA_STREAM_BYTES)); then
    VMA_ESTIMATED_BYTES="$((VMA_STREAM_BYTES - VMA_SPARSE_BYTES))"
  else
    VMA_ESTIMATED_BYTES="${VMA_DEVICE_BYTES}"
  fi

  if ((DRY_RUN == 0)) && [[ -n "${ACTIVE_MANIFEST}" && -f "${ACTIVE_MANIFEST}" ]]; then
    restore.manifest_put "${ACTIVE_MANIFEST}" local_bytes "${LOCAL_BYTES}"
    restore.manifest_put "${ACTIVE_MANIFEST}" local_sha256 "${LOCAL_SHA256}"
    restore.manifest_put "${ACTIVE_MANIFEST}" vma_device_bytes "${VMA_DEVICE_BYTES}"
    restore.manifest_put "${ACTIVE_MANIFEST}" vma_sparse_bytes "${VMA_SPARSE_BYTES}"
    restore.manifest_put "${ACTIVE_MANIFEST}" vma_stream_bytes "${VMA_STREAM_BYTES}"
    restore.manifest_put "${ACTIVE_MANIFEST}" restore_estimate_bytes "${VMA_ESTIMATED_BYTES}"
    restore.manifest_put "${ACTIVE_MANIFEST}" verified_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    restore.manifest_put "${ACTIVE_MANIFEST}" phase verified
  fi
  restore.log "archive verified: source VM ${SOURCE_VM_ID}, $(restore.human_bytes "${LOCAL_BYTES}"), devices $(restore.human_bytes "${VMA_DEVICE_BYTES}")"
}

check_restore_capacity() {
  CURRENT_PHASE="capacity"
  local metadata pool_size data_percent metadata_percent projected
  metadata="$("${STORAGE_TEMP}" --action status --vm "${VM_ID}" --storage "${TARGET_STORAGE}" \
    --mount-root "${MOUNT_ROOT}" --max-thin-data-percent "${MAX_THIN_DATA_PERCENT}" \
    --max-thin-metadata-percent "${MAX_THIN_METADATA_PERCENT}" --output json)"
  restore.json_require "${metadata}" '
    type == "object"
    and (.pool_size_bytes | type == "number" and . > 0 and floor == .)
    and (.data_percent | type == "number" and . >= 0)
    and (.metadata_percent | type == "number" and . >= 0)
  ' "target storage helper" "${RESTORE_EXIT_INTEGRITY}"
  pool_size="$(restore.json_get "${metadata}" '.pool_size_bytes | tostring' "target pool size" "${RESTORE_EXIT_INTEGRITY}")"
  data_percent="$(restore.json_get "${metadata}" '.data_percent | tostring' "target data percentage" "${RESTORE_EXIT_INTEGRITY}")"
  metadata_percent="$(restore.json_get "${metadata}" '.metadata_percent | tostring' "target metadata percentage" "${RESTORE_EXIT_INTEGRITY}")"
  projected="$(awk -v size="${pool_size}" -v used="${data_percent}" -v add="${VMA_ESTIMATED_BYTES}" \
    'BEGIN {printf "%.4f", used + ((add / size) * 100)}')"
  local refused=0
  awk -v actual="${metadata_percent}" -v max="${MAX_THIN_METADATA_PERCENT}" 'BEGIN {exit !(actual >= max)}' && refused=1
  awk -v actual="${projected}" -v max="${MAX_THIN_DATA_PERCENT}" 'BEGIN {exit !(actual >= max)}' && refused=1
  if ((refused)); then
    restore.warn "target capacity gate: current data ${data_percent}%, projected ${projected}%, metadata ${metadata_percent}%"
    ((CAPACITY_OVERRIDE)) || restore.die "${RESTORE_EXIT_INTEGRITY}" "restore would violate the target thin-pool threshold"
    if ((DRY_RUN)); then
      restore.log "dry-run: a real run would require the exact target capacity-override confirmation"
    else
      restore.confirm_exact "override capacity for VM ${VM_ID}" "target capacity override" "${RESTORE_EXIT_INTEGRITY}"
    fi
  fi
  restore.log "target capacity accepted: current ${data_percent}%, projected ${projected}%, metadata ${metadata_percent}%"
}

check_vm_collision() {
  CURRENT_PHASE="collision"
  local local_node config_node status
  local -a config_paths=()
  local_node="$(hostname -s)"
  shopt -s nullglob
  config_paths=(/etc/pve/nodes/*/qemu-server/"${VM_ID}.conf")
  shopt -u nullglob
  ((${#config_paths[@]} <= 1)) || restore.die "${RESTORE_EXIT_COLLISION}" "multiple cluster configurations exist for VM ${VM_ID}"
  if ((${#config_paths[@]} == 0)); then
    RESTORE_REPLACEMENT=0
    ((REPLACE_EXISTING == 0)) || restore.warn "--replace-existing was supplied, but target VM ${VM_ID} is unused"
    return 0
  fi

  config_node="${config_paths[0]#*/nodes/}"
  config_node="${config_node%%/*}"
  [[ "${config_node}" == "${local_node}" ]] || \
    restore.die "${RESTORE_EXIT_COLLISION}" "VM ${VM_ID} exists on node ${config_node}; local node is ${local_node}"
  status="$(qm status "${VM_ID}" 2>/dev/null | awk '{print $2}')"
  [[ "${status}" != running ]] || restore.die "${RESTORE_EXIT_COLLISION}" "VM ${VM_ID} is running"
  [[ "${status}" == stopped ]] || restore.die "${RESTORE_EXIT_COLLISION}" "VM ${VM_ID} has unsupported status: ${status:-unknown}"
  if ha-manager config 2>/dev/null | grep -Eq "^[[:space:]]*vm:${VM_ID}([[:space:]]|$)"; then
    restore.die "${RESTORE_EXIT_COLLISION}" "VM ${VM_ID} is HA-managed"
  fi
  ((REPLACE_EXISTING)) || restore.die "${RESTORE_EXIT_COLLISION}" "stopped local VM ${VM_ID} exists; use --replace-existing after review"
  restore.log "existing target configuration follows"
  qm config "${VM_ID}" >&2
  if ((DRY_RUN)); then
    restore.log "dry-run: a real run would require: replace VM ${VM_ID} on ${local_node}"
  else
    restore.confirm_exact "replace VM ${VM_ID} on ${local_node}" "replacement of stopped local VM ${VM_ID}" "${RESTORE_EXIT_COLLISION}"
  fi
  RESTORE_REPLACEMENT=1
}

restore_vm() {
  CURRENT_PHASE="restore"
  local -a command=(qmrestore "${ARCHIVE}" "${VM_ID}" --storage "${TARGET_STORAGE}")
  ((RESTORE_REPLACEMENT)) && command+=(--force 1)
  ((UNIQUE)) && command+=(--unique 1)
  [[ -z "${RESTORE_BWLIMIT_KBPS}" ]] || command+=(--bwlimit "${RESTORE_BWLIMIT_KBPS}")
  restore.log "starting native qmrestore for target VM ${VM_ID}"
  if ! restore.run "${command[@]}"; then
    restore.die "${RESTORE_EXIT_RESTORE}" "qmrestore failed; the archive and staging LV were retained"
  fi
  if ((DRY_RUN)); then
    return 0
  fi

  local config status
  config="$(qm config "${VM_ID}")" || restore.die "${RESTORE_EXIT_RESTORE}" "restored VM configuration cannot be read"
  printf '%s\n' "${config}" >&2
  grep -q '^lock:' <<<"${config}" && restore.die "${RESTORE_EXIT_RESTORE}" "restored VM retains a Proxmox lock"
  status="$(qm status "${VM_ID}")" || restore.die "${RESTORE_EXIT_RESTORE}" "restored VM status cannot be read"
  restore.log "${status}"
  pvesm list "${TARGET_STORAGE}" --vmid "${VM_ID}" >&2 || restore.die "${RESTORE_EXIT_RESTORE}" "target volumes cannot be listed"
  sync
  if [[ -n "${ACTIVE_MANIFEST}" && -f "${ACTIVE_MANIFEST}" ]]; then
    restore.manifest_put "${ACTIVE_MANIFEST}" phase restored
  fi
}

cleanup_stage_if_owned() {
  CURRENT_PHASE="cleanup"
  if [[ -z "${ACTIVE_MANIFEST}" || ! -f "${ACTIVE_MANIFEST}" ]]; then
    restore.log "archive is not in a manifest-owned stage; no temporary LV cleanup is needed"
    return 0
  fi
  local -a stage_args=()
  storage_args stage_args
  "${STORAGE_TEMP}" --action remove "${stage_args[@]}" --output human || \
    restore.die "${RESTORE_EXIT_CLEANUP}" "staging cleanup failed"
  ACTIVE_MANIFEST=""
}

start_vm_if_requested() {
  ((START_VM)) || return 0
  CURRENT_PHASE="start"
  restore.run qm start "${VM_ID}" || restore.die "${RESTORE_EXIT_RESTORE}" "restored VM could not be started"
  if ((DRY_RUN == 0)); then
    qm status "${VM_ID}" >&2
  fi
}

emit_result() {
  local human="$1"
  local result_bytes="${LOCAL_BYTES:-${REMOTE_BYTES:-0}}"
  local result_sha="${LOCAL_SHA256:-${REMOTE_SHA256}}"
  local json=""
  if [[ "${OUTPUT}" == json ]]; then
    json="$(jq -cn \
      --arg action "${ACTION}" \
      --arg target_vm "${VM_ID}" \
      --arg source_vm "${SOURCE_VM_ID}" \
      --arg archive "${ARCHIVE}" \
      --arg bytes "${result_bytes}" \
      --arg sha256 "${result_sha}" \
      '{
        action: $action,
        target_vm: ($target_vm | tonumber),
        source_vm: (if $source_vm == "" then null else ($source_vm | tonumber) end),
        archive: (if $archive == "" then null else $archive end),
        bytes: ($bytes | tonumber),
        sha256: (if $sha256 == "" then null else $sha256 end)
      }')"
  fi
  restore.emit "${OUTPUT}" "${human}" "${ARCHIVE:-${MOUNT_ROOT%/}/${VM_ID}}" \
    "${result_bytes}" "${result_sha}" "${json}"
}

dry_run_post_transfer() {
  CURRENT_PHASE="dry-run-plan"
  restore.log "dry-run: transferred archive does not exist, so integrity and mutation commands are rendered only"
  if [[ "${ARCHIVE}" == *.vma.zst ]]; then
    restore.render_command zstd --no-progress --decompress --stdout "${ARCHIVE}"
    restore.render_command vma verify -v /dev/stdin
  else
    restore.render_command vma verify -v "${ARCHIVE}"
  fi
  check_vm_collision
  CURRENT_PHASE="dry-run-plan"
  local -a command=(qmrestore "${ARCHIVE}" "${VM_ID}" --storage "${TARGET_STORAGE}")
  if ((RESTORE_REPLACEMENT)); then
    command+=(--force 1)
  fi
  if ((UNIQUE)); then
    command+=(--unique 1)
  fi
  if [[ -n "${RESTORE_BWLIMIT_KBPS}" ]]; then
    command+=(--bwlimit "${RESTORE_BWLIMIT_KBPS}")
  fi
  restore.render_command "${command[@]}"
  if [[ "${CLEANUP_POLICY}" == success ]]; then
    restore.render_command "${STORAGE_TEMP}" --action remove --vm "${VM_ID}" --storage "${STAGE_STORAGE}" --mount-root "${MOUNT_ROOT}"
  fi
  if ((START_VM)); then
    restore.render_command qm start "${VM_ID}"
  fi
  return 0
}

case "${ACTION}" in
  preflight)
    local_preflight
    [[ -z "${REMOTE_PATH}" ]] || inspect_remote_archive
    emit_result "preflight passed for target VM ${VM_ID}"
    ;;
  transfer)
    local_preflight
    perform_transfer
    emit_result "archive transferred and checksum-matched: ${ARCHIVE}"
    ;;
  verify)
    local_preflight
    verify_archive
    emit_result "archive verification passed: ${ARCHIVE}"
    ;;
  restore)
    local_preflight
    verify_archive
    check_vm_collision
    check_restore_capacity
    restore_vm
    [[ "${CLEANUP_POLICY}" == never ]] || cleanup_stage_if_owned
    start_vm_if_requested
    emit_result "VM ${VM_ID} restored successfully"
    ;;
  cleanup)
    local_preflight
    ACTIVE_MANIFEST="${MOUNT_ROOT%/}/${VM_ID}/.proxmox-restore.tsv"
    declare -a local_cleanup_args=(--vm "${VM_ID}" --storage "${STAGE_STORAGE}" --mount-root "${MOUNT_ROOT}" --output path)
    ((DRY_RUN)) && local_cleanup_args+=(--dry-run)
    if ! ARCHIVE="$("${STORAGE_TEMP}" --action remove "${local_cleanup_args[@]}")"; then
      restore.die "${RESTORE_EXIT_CLEANUP}" "staging cleanup failed"
    fi
    ACTIVE_MANIFEST=""
    emit_result "staging cleanup completed for VM ${VM_ID}"
    ;;
  all)
    local_preflight
    perform_transfer
    if ((DRY_RUN)); then
      dry_run_post_transfer
      emit_result "dry-run completed without mutation"
      exit 0
    fi
    verify_archive
    check_vm_collision
    check_restore_capacity
    restore_vm
    [[ "${CLEANUP_POLICY}" == never ]] || cleanup_stage_if_owned
    start_vm_if_requested
    emit_result "VM ${VM_ID} restored successfully"
    ;;
esac

CURRENT_PHASE="complete"
