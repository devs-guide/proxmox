#!/usr/bin/env bash
set -euo pipefail

RESTORE_COMPONENT="cli.storage.temp"
PAGES_BASE_URL="${PROXMOX_RESTORE_PAGES_BASE_URL:-https://devs-guide.github.io/proxmox}"
FEATURE_TMP_DIR="${PROXMOX_RESTORE_TMP_DIR:-/tmp/pve-feature-vm-restore}"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
COMMON_PATH=""

bootstrap.common.error() {
  printf '[%s][error] %s\n' "${RESTORE_COMPONENT}" "$*" >&2
}

bootstrap.common.fetch() {
  local destination="${FEATURE_TMP_DIR}/cli/lib/restore.common.sh"
  local temporary="${destination}.tmp.$$"
  mkdir -p "$(dirname "${destination}")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${PAGES_BASE_URL}/cli/lib/restore.common.sh" -o "${temporary}" || {
      rm -f "${temporary}"
      bootstrap.common.error "failed to fetch ${PAGES_BASE_URL}/cli/lib/restore.common.sh"
      exit 10
    }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${temporary}" "${PAGES_BASE_URL}/cli/lib/restore.common.sh" || {
      rm -f "${temporary}"
      bootstrap.common.error "failed to fetch ${PAGES_BASE_URL}/cli/lib/restore.common.sh"
      exit 10
    }
  else
    bootstrap.common.error "curl or wget is required to fetch restore.common.sh"
    exit 10
  fi
  chmod 0644 "${temporary}"
  mv -f "${temporary}" "${destination}"
  printf '%s\n' "${destination}"
}

if [[ -n "${SCRIPT_SOURCE}" && -f "${SCRIPT_SOURCE}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
  [[ -r "${SCRIPT_DIR}/../lib/restore.common.sh" ]] && COMMON_PATH="${SCRIPT_DIR}/../lib/restore.common.sh"
fi
[[ -n "${COMMON_PATH}" ]] || COMMON_PATH="$(bootstrap.common.fetch)"
# shellcheck source=../lib/restore.common.sh
source "${COMMON_PATH}"

ACTION="status"
VM_ID=""
SOURCE_VM_ID=""
STORAGE="local-lvm"
SOURCE_BYTES=""
STAGE_SIZE="auto"
MOUNT_ROOT="/mnt/pve-restore"
MAX_THIN_DATA_PERCENT="85"
MAX_THIN_METADATA_PERCENT="75"
REMOTE_HOST=""
REMOTE_USER="root"
REMOTE_PATH=""
REMOTE_SHA256=""
ARCHIVE_BASENAME=""
CAPACITY_OVERRIDE=0
YES=0
OUTPUT="human"
DRY_RUN=0
STORAGE_CONFIG="${PROXMOX_STORAGE_CONFIG:-/etc/pve/storage.cfg}"

usage() {
  cat <<'EOF'
Usage: cli/storage/temp.sh --action create|status|remove --vm ID [options]

Create, resume, inspect, or remove one manifest-owned temporary filesystem on a
thin LV. The selected Proxmox lvmthin storage is resolved from storage.cfg.

Required:
  --vm ID
  --source-bytes BYTES              Required for create with --stage-size auto

Options:
  --action create|status|remove     Default: status
  --source-vm ID
  --storage STORAGE                 Default: local-lvm
  --source-bytes BYTES
  --stage-size auto|SIZE            Default: auto; SIZE accepts bytes or K/M/G/T
  --mount-root PATH                 Default: /mnt/pve-restore
  --max-thin-data-percent PERCENT   Default: 85
  --max-thin-metadata-percent PERCENT Default: 75
  --remote-host HOST                Manifest metadata
  --remote-user USER                Manifest metadata; default: root
  --remote-path PATH                Manifest metadata
  --remote-sha256 HEX               Manifest metadata
  --archive-basename NAME           Manifest metadata
  --capacity-override               Confirm bypass of the projected capacity gate
  --yes                             Noninteractive capacity-override confirmation
  --output human|path|bytes|tsv
  --dry-run
  --help

Examples:
  cli/storage/temp.sh --action create --vm 321 --storage local-lvm \
    --source-bytes 2147483648 --output path
  cli/storage/temp.sh --action remove --vm 321 --storage local-lvm

Published runner:
  wget -qO- https://devs-guide.github.io/proxmox/cli/storage/temp.sh | \
    bash -s -- --action status --vm 321
EOF
}

while (($#)); do
  case "$1" in
    --action) restore.require_flag_value "$1" "${2-}"; ACTION="$2"; shift 2 ;;
    --vm) restore.require_flag_value "$1" "${2-}"; VM_ID="$2"; shift 2 ;;
    --source-vm) restore.require_flag_value "$1" "${2-}"; SOURCE_VM_ID="$2"; shift 2 ;;
    --storage) restore.require_flag_value "$1" "${2-}"; STORAGE="$2"; shift 2 ;;
    --source-bytes) restore.require_flag_value "$1" "${2-}"; SOURCE_BYTES="$2"; shift 2 ;;
    --stage-size) restore.require_flag_value "$1" "${2-}"; STAGE_SIZE="$2"; shift 2 ;;
    --mount-root) restore.require_flag_value "$1" "${2-}"; MOUNT_ROOT="$2"; shift 2 ;;
    --max-thin-data-percent) restore.require_flag_value "$1" "${2-}"; MAX_THIN_DATA_PERCENT="$2"; shift 2 ;;
    --max-thin-metadata-percent) restore.require_flag_value "$1" "${2-}"; MAX_THIN_METADATA_PERCENT="$2"; shift 2 ;;
    --remote-host) restore.require_flag_value "$1" "${2-}"; REMOTE_HOST="$2"; shift 2 ;;
    --remote-user) restore.require_flag_value "$1" "${2-}"; REMOTE_USER="$2"; shift 2 ;;
    --remote-path) restore.require_flag_value "$1" "${2-}"; REMOTE_PATH="$2"; shift 2 ;;
    --remote-sha256) restore.require_flag_value "$1" "${2-}"; REMOTE_SHA256="$2"; shift 2 ;;
    --archive-basename) restore.require_flag_value "$1" "${2-}"; ARCHIVE_BASENAME="$2"; shift 2 ;;
    --capacity-override) CAPACITY_OVERRIDE=1; shift ;;
    --yes) YES=1; shift ;;
    --output) restore.require_flag_value "$1" "${2-}"; OUTPUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) restore.die "${RESTORE_EXIT_USAGE}" "unknown flag: $1" ;;
    *) restore.die "${RESTORE_EXIT_USAGE}" "positional arguments are not supported: $1" ;;
  esac
done

[[ "${ACTION}" == create || "${ACTION}" == status || "${ACTION}" == remove ]] || \
  restore.die "${RESTORE_EXIT_USAGE}" "--action must be create, status, or remove"
[[ -n "${VM_ID}" ]] || restore.die "${RESTORE_EXIT_USAGE}" "--vm is required"
restore.validate_vm_id "${VM_ID}"
[[ -z "${SOURCE_VM_ID}" ]] || restore.validate_vm_id "${SOURCE_VM_ID}"
restore.validate_storage_id "${STORAGE}"
restore.validate_percent "--max-thin-data-percent" "${MAX_THIN_DATA_PERCENT}"
restore.validate_percent "--max-thin-metadata-percent" "${MAX_THIN_METADATA_PERCENT}"
restore.validate_output "${OUTPUT}" human path bytes tsv
[[ "${MOUNT_ROOT}" == /* && "${MOUNT_ROOT}" != *'/../'* && "${MOUNT_ROOT}" != */.. ]] || \
  restore.die "${RESTORE_EXIT_USAGE}" "--mount-root must be an absolute normalized path"
[[ -z "${SOURCE_BYTES}" ]] || restore.validate_positive_uint "--source-bytes" "${SOURCE_BYTES}"
[[ -z "${SOURCE_BYTES}" ]] || SOURCE_BYTES="$((10#${SOURCE_BYTES}))"
[[ "${STAGE_SIZE}" == auto ]] || restore.parse_size_bytes "${STAGE_SIZE}" >/dev/null
if [[ "${ACTION}" == create && "${STAGE_SIZE}" == auto && -z "${SOURCE_BYTES}" ]]; then
  restore.die "${RESTORE_EXIT_USAGE}" "--source-bytes is required for automatic stage sizing"
fi
[[ -z "${REMOTE_SHA256}" || "${REMOTE_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] || \
  restore.die "${RESTORE_EXIT_USAGE}" "--remote-sha256 must be 64 hexadecimal characters"

restore.require_proxmox
restore.require_commands "${RESTORE_EXIT_STORAGE}" pvesm lvs vgs lvcreate lvremove mkfs.ext4 mount umount findmnt lsblk awk
[[ -r "${STORAGE_CONFIG}" ]] || restore.die "${RESTORE_EXIT_STORAGE}" "cannot read Proxmox storage configuration: ${STORAGE_CONFIG}"

LV_NAME="$(restore.stage_lv_name "${VM_ID}")"
MOUNTPOINT="$(restore.stage_mountpoint "${MOUNT_ROOT}" "${VM_ID}")"
MANIFEST="${MOUNTPOINT}/.proxmox-restore.tsv"
FS_LABEL="pve_restore_vm${VM_ID}"
FS_UUID=""
VG_NAME=""
THIN_POOL=""
POOL_SIZE_BYTES=""
POOL_DATA_PERCENT=""
POOL_METADATA_PERCENT=""
VG_FREE_BYTES=""
STAGE_BYTES=""
DEVICE=""

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "${value}"
}

resolve_storage() {
  local resolved
  resolved="$(awk -v wanted="${STORAGE}" '
    /^[^[:space:]#][^:]*:[[:space:]]+/ {
      if (active && vg != "" && pool != "") { print vg "\t" pool; active=0; exit }
      active=($1 == "lvmthin:" && $2 == wanted)
      if (active) { vg=""; pool="" }
      next
    }
    active && $1 == "vgname" { vg=$2 }
    active && $1 == "thinpool" { pool=$2 }
    END { if (active && vg != "" && pool != "") print vg "\t" pool }
  ' "${STORAGE_CONFIG}")"
  IFS=$'\t' read -r VG_NAME THIN_POOL <<<"${resolved}"
  [[ -n "${VG_NAME}" && -n "${THIN_POOL}" ]] || \
    restore.die "${RESTORE_EXIT_STORAGE}" "storage ${STORAGE} is not a configured lvmthin storage with vgname and thinpool"
  [[ "${VG_NAME}" =~ ^[a-zA-Z0-9+_.-]+$ && "${THIN_POOL}" =~ ^[a-zA-Z0-9+_.-]+$ ]] || \
    restore.die "${RESTORE_EXIT_STORAGE}" "storage ${STORAGE} resolved to unsafe LVM names"
  DEVICE="/dev/${VG_NAME}/${LV_NAME}"
  [[ "${LV_NAME}" != "${THIN_POOL}" && "${LV_NAME}" != *_tdata && "${LV_NAME}" != *_tmeta ]] || \
    restore.die "${RESTORE_EXIT_STORAGE}" "derived staging LV conflicts with protected thin-pool components"
}

read_pool_status() {
  local row lv_name lv_size data_percent metadata_percent lv_attr
  row="$(lvs --noheadings --unquoted --units b --nosuffix --separator '|' \
    -o lv_name,lv_size,data_percent,metadata_percent,lv_attr "${VG_NAME}/${THIN_POOL}" 2>/dev/null | head -n1)" || true
  [[ -n "${row}" ]] || restore.die "${RESTORE_EXIT_STORAGE}" "thin pool not found: ${VG_NAME}/${THIN_POOL}"
  IFS='|' read -r lv_name lv_size data_percent metadata_percent lv_attr <<<"${row}"
  lv_name="$(trim "${lv_name}")"
  POOL_SIZE_BYTES="$(trim "${lv_size}")"
  POOL_DATA_PERCENT="$(trim "${data_percent}")"
  POOL_METADATA_PERCENT="$(trim "${metadata_percent}")"
  lv_attr="$(trim "${lv_attr}")"
  [[ "${lv_name}" == "${THIN_POOL}" && "${lv_attr}" == t* ]] || \
    restore.die "${RESTORE_EXIT_STORAGE}" "${VG_NAME}/${THIN_POOL} is not an LVM thin pool"
  [[ "${POOL_SIZE_BYTES}" =~ ^[0-9]+([.][0-9]+)?$ && "${POOL_DATA_PERCENT}" =~ ^[0-9]+([.][0-9]+)?$ && "${POOL_METADATA_PERCENT}" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
    restore.die "${RESTORE_EXIT_STORAGE}" "could not parse thin-pool size or utilization"
  VG_FREE_BYTES="$(vgs --noheadings --unquoted --units b --nosuffix -o vg_free "${VG_NAME}" 2>/dev/null | tr -d '[:space:]')" || true
  [[ "${VG_FREE_BYTES}" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
    restore.die "${RESTORE_EXIT_STORAGE}" "could not validate physical free extents for VG ${VG_NAME}"
}

stage_exists() {
  lvs "${VG_NAME}/${LV_NAME}" >/dev/null 2>&1
}

validate_stage_lv() {
  local row actual_vg actual_pool lv_attr
  row="$(lvs --noheadings --unquoted --separator '|' -o vg_name,pool_lv,lv_attr "${VG_NAME}/${LV_NAME}" 2>/dev/null | head -n1)" || true
  [[ -n "${row}" ]] || restore.die "${RESTORE_EXIT_STORAGE}" "staging LV disappeared: ${VG_NAME}/${LV_NAME}"
  IFS='|' read -r actual_vg actual_pool lv_attr <<<"${row}"
  actual_vg="$(trim "${actual_vg}")"
  actual_pool="$(trim "${actual_pool}")"
  lv_attr="$(trim "${lv_attr}")"
  [[ "${actual_vg}" == "${VG_NAME}" && "${actual_pool}" == "${THIN_POOL}" && "${lv_attr}" == V* ]] || \
    restore.die "${RESTORE_EXIT_STORAGE}" "existing LV ${VG_NAME}/${LV_NAME} is not the expected thin volume in ${THIN_POOL}"
}

validate_stage_filesystem() {
  local filesystem label
  filesystem="$(lsblk -dnro FSTYPE "${DEVICE}" 2>/dev/null | head -n1)"
  label="$(lsblk -dnro LABEL "${DEVICE}" 2>/dev/null | head -n1)"
  FS_UUID="$(lsblk -dnro UUID "${DEVICE}" 2>/dev/null | head -n1)"
  [[ "${filesystem}" == ext4 ]] || restore.die "${RESTORE_EXIT_STORAGE}" "stage filesystem is not ext4: ${filesystem:-missing}"
  [[ "${label}" == "${FS_LABEL}" ]] || restore.die "${RESTORE_EXIT_STORAGE}" "stage filesystem label mismatch: ${label:-missing}"
  [[ "${FS_UUID}" =~ ^[0-9a-fA-F-]{16,}$ ]] || restore.die "${RESTORE_EXIT_STORAGE}" "stage filesystem UUID is missing or invalid"
}

mount_stage() {
  if [[ -L "${MOUNTPOINT}" ]]; then
    restore.die "${RESTORE_EXIT_STORAGE}" "stage mountpoint is a symlink: ${MOUNTPOINT}"
  fi
  restore.run install -d -m 0700 "${MOUNTPOINT}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    restore.render_command mount -o nodev,nosuid,noexec "${DEVICE}" "${MOUNTPOINT}"
    return 0
  fi
  local mounted_source mounted_target canonical_source canonical_device
  mounted_source="$(findmnt -rn -M "${MOUNTPOINT}" -o SOURCE 2>/dev/null || true)"
  mounted_target="$(findmnt -rn -S "${DEVICE}" -o TARGET 2>/dev/null || true)"
  if [[ -n "${mounted_source}" || -n "${mounted_target}" ]]; then
    canonical_source="$(readlink -f "${mounted_source}" 2>/dev/null || true)"
    canonical_device="$(readlink -f "${DEVICE}" 2>/dev/null || true)"
    [[ -n "${canonical_source}" && "${canonical_source}" == "${canonical_device}" && "${mounted_target}" == "${MOUNTPOINT}" ]] || \
      restore.die "${RESTORE_EXIT_STORAGE}" "stage device or mountpoint is already mounted somewhere unexpected"
  else
    mount -o nodev,nosuid,noexec "${DEVICE}" "${MOUNTPOINT}" >&2 || \
      restore.die "${RESTORE_EXIT_STORAGE}" "could not mount ${DEVICE} at ${MOUNTPOINT}"
  fi
  chmod 0700 "${MOUNTPOINT}"
}

validate_manifest() {
  [[ -f "${MANIFEST}" && ! -L "${MANIFEST}" ]] || \
    restore.die "${RESTORE_EXIT_STORAGE}" "existing stage is not owned by a valid restore manifest: ${MANIFEST}"
  restore.manifest_require "${MANIFEST}" target_vm "${VM_ID}"
  restore.manifest_require "${MANIFEST}" storage "${STORAGE}"
  restore.manifest_require "${MANIFEST}" vg "${VG_NAME}"
  restore.manifest_require "${MANIFEST}" thin_pool "${THIN_POOL}"
  restore.manifest_require "${MANIFEST}" lv "${LV_NAME}"
  restore.manifest_require "${MANIFEST}" device "${DEVICE}"
  restore.manifest_require "${MANIFEST}" mountpoint "${MOUNTPOINT}"
  restore.manifest_require "${MANIFEST}" filesystem_uuid "${FS_UUID}"
  [[ -z "${SOURCE_VM_ID}" ]] || restore.manifest_require "${MANIFEST}" source_vm "${SOURCE_VM_ID}"
  [[ -z "${REMOTE_HOST}" ]] || restore.manifest_require "${MANIFEST}" remote_host "${REMOTE_HOST}"
  [[ -z "${REMOTE_PATH}" ]] || restore.manifest_require "${MANIFEST}" remote_path "${REMOTE_PATH}"
  [[ -z "${REMOTE_SHA256}" ]] || restore.manifest_require "${MANIFEST}" remote_sha256 "${REMOTE_SHA256}"
}

write_manifest() {
  restore.manifest_put "${MANIFEST}" manifest_version 1
  restore.manifest_put "${MANIFEST}" target_vm "${VM_ID}"
  restore.manifest_put "${MANIFEST}" source_vm "${SOURCE_VM_ID}"
  restore.manifest_put "${MANIFEST}" storage "${STORAGE}"
  restore.manifest_put "${MANIFEST}" vg "${VG_NAME}"
  restore.manifest_put "${MANIFEST}" thin_pool "${THIN_POOL}"
  restore.manifest_put "${MANIFEST}" lv "${LV_NAME}"
  restore.manifest_put "${MANIFEST}" device "${DEVICE}"
  restore.manifest_put "${MANIFEST}" mountpoint "${MOUNTPOINT}"
  restore.manifest_put "${MANIFEST}" filesystem ext4
  restore.manifest_put "${MANIFEST}" filesystem_label "${FS_LABEL}"
  restore.manifest_put "${MANIFEST}" filesystem_uuid "${FS_UUID}"
  restore.manifest_put "${MANIFEST}" stage_bytes "${STAGE_BYTES}"
  restore.manifest_put "${MANIFEST}" source_bytes "${SOURCE_BYTES}"
  restore.manifest_put "${MANIFEST}" remote_host "${REMOTE_HOST}"
  restore.manifest_put "${MANIFEST}" remote_user "${REMOTE_USER}"
  restore.manifest_put "${MANIFEST}" remote_path "${REMOTE_PATH}"
  restore.manifest_put "${MANIFEST}" remote_sha256 "${REMOTE_SHA256}"
  restore.manifest_put "${MANIFEST}" archive_basename "${ARCHIVE_BASENAME}"
  restore.manifest_put "${MANIFEST}" phase staging
  restore.manifest_put "${MANIFEST}" created_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

calculate_stage_size() {
  if [[ "${STAGE_SIZE}" == auto ]]; then
    STAGE_BYTES="$(restore.auto_stage_bytes "${SOURCE_BYTES}")"
  else
    STAGE_BYTES="$(restore.parse_size_bytes "${STAGE_SIZE}")"
  fi
  if [[ -n "${SOURCE_BYTES}" && "${STAGE_BYTES}" -le "${SOURCE_BYTES}" ]]; then
    restore.die "${RESTORE_EXIT_STORAGE}" "stage size must be larger than the remote archive"
  fi
}

check_stage_capacity() {
  local projected_data
  projected_data="$(awk -v size="${POOL_SIZE_BYTES}" -v used="${POOL_DATA_PERCENT}" -v add="${STAGE_BYTES:-0}" \
    'BEGIN {printf "%.4f", used + ((add / size) * 100)}')"
  local refused=0
  awk -v actual="${POOL_METADATA_PERCENT}" -v max="${MAX_THIN_METADATA_PERCENT}" 'BEGIN {exit !(actual >= max)}' && refused=1
  awk -v projected="${projected_data}" -v max="${MAX_THIN_DATA_PERCENT}" 'BEGIN {exit !(projected >= max)}' && refused=1
  if ((refused)); then
    restore.warn "thin-pool gate: current data ${POOL_DATA_PERCENT}%, projected stage data ${projected_data}%, metadata ${POOL_METADATA_PERCENT}%"
    ((CAPACITY_OVERRIDE)) || restore.die "${RESTORE_EXIT_INTEGRITY}" "staging would violate the configured thin-pool threshold"
    if [[ "${DRY_RUN}" == "1" ]]; then
      restore.log "dry-run: a real run would require the exact capacity-override confirmation"
    else
      restore.confirm_exact "override capacity for VM ${VM_ID}" "capacity override for ${VG_NAME}/${THIN_POOL}" "${RESTORE_EXIT_INTEGRITY}"
    fi
  fi
}

emit_status() {
  local state="$1"
  local human="stage ${state}: ${VG_NAME}/${LV_NAME} -> ${MOUNTPOINT}; pool data ${POOL_DATA_PERCENT}%, metadata ${POOL_METADATA_PERCENT}%"
  local tsv="state\t${state}\tstorage\t${STORAGE}\tvg\t${VG_NAME}\tthin_pool\t${THIN_POOL}\tlv\t${LV_NAME}\tdevice\t${DEVICE}\tmountpoint\t${MOUNTPOINT}\tstage_bytes\t${STAGE_BYTES:-0}\tpool_size_bytes\t${POOL_SIZE_BYTES}\tdata_percent\t${POOL_DATA_PERCENT}\tmetadata_percent\t${POOL_METADATA_PERCENT}\tvg_free_bytes\t${VG_FREE_BYTES}"
  restore.emit "${OUTPUT}" "${human}" "${MOUNTPOINT}" "${STAGE_BYTES:-0}" "" "${tsv}"
}

create_stage() {
  calculate_stage_size
  if stage_exists; then
    restore.log "resuming existing deterministic stage LV ${VG_NAME}/${LV_NAME}"
    validate_stage_lv
    validate_stage_filesystem
    mount_stage
    [[ "${DRY_RUN}" == "1" ]] || validate_manifest
    if [[ "${DRY_RUN}" != "1" ]]; then
      local manifest_stage_bytes
      manifest_stage_bytes="$(restore.manifest_get "${MANIFEST}" stage_bytes)"
      [[ "${manifest_stage_bytes}" == "${STAGE_BYTES}" ]] || \
        restore.die "${RESTORE_EXIT_STORAGE}" "requested stage size differs from the existing manifest"
    fi
    emit_status resumed
    return 0
  fi

  check_stage_capacity
  restore.log "creating disposable thin LV ${VG_NAME}/${LV_NAME} ($(restore.human_bytes "${STAGE_BYTES}"))"
  if [[ "${DRY_RUN}" == "1" ]]; then
    restore.render_command lvcreate --yes --type thin --virtualsize "${STAGE_BYTES}B" --name "${LV_NAME}" "${VG_NAME}/${THIN_POOL}"
    restore.render_command mkfs.ext4 -q -m 0 -L "${FS_LABEL}" "${DEVICE}"
    mount_stage
    emit_status planned
    return 0
  fi

  lvcreate --yes --type thin --virtualsize "${STAGE_BYTES}B" --name "${LV_NAME}" "${VG_NAME}/${THIN_POOL}" >&2 || \
    restore.die "${RESTORE_EXIT_STORAGE}" "lvcreate failed"
  validate_stage_lv
  [[ -b "${DEVICE}" ]] || restore.die "${RESTORE_EXIT_STORAGE}" "new stage device is not a block device: ${DEVICE}"
  mkfs.ext4 -q -m 0 -L "${FS_LABEL}" "${DEVICE}" >&2 || \
    restore.die "${RESTORE_EXIT_STORAGE}" "mkfs.ext4 failed on the newly created stage LV"
  validate_stage_filesystem
  mount_stage
  write_manifest
  sync "${MANIFEST}"
  emit_status created
}

status_stage() {
  if stage_exists; then
    validate_stage_lv
    STAGE_BYTES="$(lvs --noheadings --units b --nosuffix -o lv_size "${VG_NAME}/${LV_NAME}" | tr -d '[:space:]')"
    emit_status present
  else
    emit_status absent
  fi
}

remove_stage() {
  if ! stage_exists; then
    restore.log "stage LV is already absent: ${VG_NAME}/${LV_NAME}"
    emit_status absent
    return 0
  fi
  validate_stage_lv
  validate_stage_filesystem
  mount_stage
  [[ "${DRY_RUN}" == "1" ]] || validate_manifest
  restore.log "removing only manifest-owned stage ${VG_NAME}/${LV_NAME}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    restore.render_command umount "${MOUNTPOINT}"
    restore.render_command lvremove --yes "${VG_NAME}/${LV_NAME}"
    restore.render_command rmdir "${MOUNTPOINT}"
    emit_status planned-removal
    return 0
  fi
  local mounted_source canonical_source canonical_device
  mounted_source="$(findmnt -rn -M "${MOUNTPOINT}" -o SOURCE 2>/dev/null || true)"
  canonical_source="$(readlink -f "${mounted_source}" 2>/dev/null || true)"
  canonical_device="$(readlink -f "${DEVICE}" 2>/dev/null || true)"
  [[ -n "${canonical_source}" && "${canonical_source}" == "${canonical_device}" ]] || \
    restore.die "${RESTORE_EXIT_CLEANUP}" "manifest stage source changed before cleanup"
  sync
  umount "${MOUNTPOINT}" >&2 || restore.die "${RESTORE_EXIT_CLEANUP}" "could not unmount ${MOUNTPOINT}"
  lvremove --yes "${VG_NAME}/${LV_NAME}" >&2 || restore.die "${RESTORE_EXIT_CLEANUP}" "could not remove ${VG_NAME}/${LV_NAME}"
  rmdir "${MOUNTPOINT}" 2>/dev/null || restore.warn "mount directory retained because it is not empty: ${MOUNTPOINT}"
  STAGE_BYTES=0
  emit_status removed
}

resolve_storage
read_pool_status
case "${ACTION}" in
  create) create_stage ;;
  status) status_stage ;;
  remove) remove_stage ;;
esac
