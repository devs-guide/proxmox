#!/usr/bin/env bash
# Shared primitives for the remote Proxmox VM restore toolchain.
# This file is sourced by the executable helpers; it is not a command itself.

if [[ -n "${PROXMOX_RESTORE_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
PROXMOX_RESTORE_COMMON_LOADED=1

RESTORE_EXIT_USAGE=2
RESTORE_EXIT_PREFLIGHT=10
RESTORE_EXIT_SSH=20
RESTORE_EXIT_STORAGE=30
RESTORE_EXIT_TRANSFER=40
RESTORE_EXIT_INTEGRITY=50
RESTORE_EXIT_COLLISION=60
RESTORE_EXIT_RESTORE=70
RESTORE_EXIT_CLEANUP=80

restore.log() {
  local component="${RESTORE_COMPONENT:-restore}"
  printf '[%s] %s\n' "${component}" "$*" >&2
}

restore.warn() {
  local component="${RESTORE_COMPONENT:-restore}"
  printf '[%s][warn] %s\n' "${component}" "$*" >&2
}

restore.error() {
  local component="${RESTORE_COMPONENT:-restore}"
  printf '[%s][error] %s\n' "${component}" "$*" >&2
}

restore.die() {
  local exit_code="$1"
  shift
  restore.error "$*"
  exit "${exit_code}"
}

restore.require_flag_value() {
  local flag="$1"
  local value="${2-}"
  [[ -n "${value}" && "${value}" != --* ]] || \
    restore.die "${RESTORE_EXIT_USAGE}" "${flag} requires a value"
  restore.validate_scalar "${flag}" "${value}"
}

restore.validate_scalar() {
  local label="$1"
  local value="$2"
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* && "${value}" != *$'\t'* ]] || \
    restore.die "${RESTORE_EXIT_USAGE}" "${label} contains a forbidden control character"
}

restore.validate_vm_id() {
  local value="$1"
  [[ "${value}" =~ ^[1-9][0-9]{2,8}$ ]] || \
    restore.die "${RESTORE_EXIT_USAGE}" "VM ID must be a positive integer of at least three digits: ${value}"
}

restore.validate_port() {
  local value="$1"
  local numeric=0
  [[ "${value}" =~ ^[0-9]+$ ]] && numeric=$((10#${value})) && ((numeric >= 1 && numeric <= 65535)) || \
    restore.die "${RESTORE_EXIT_USAGE}" "SSH port must be between 1 and 65535: ${value}"
}

restore.validate_uint() {
  local label="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || \
    restore.die "${RESTORE_EXIT_USAGE}" "${label} must be an unsigned integer: ${value}"
}

restore.validate_positive_uint() {
  local label="$1"
  local value="$2"
  restore.validate_uint "${label}" "${value}"
  ((10#${value} > 0)) || restore.die "${RESTORE_EXIT_USAGE}" "${label} must be greater than zero"
}

restore.validate_percent() {
  local label="$1"
  local value="$2"
  restore.validate_positive_uint "${label}" "${value}"
  ((10#${value} <= 100)) || restore.die "${RESTORE_EXIT_USAGE}" "${label} must not exceed 100"
}

restore.validate_remote_user() {
  local value="$1"
  [[ "${value}" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ ]] || \
    restore.die "${RESTORE_EXIT_USAGE}" "invalid remote user: ${value}"
}

restore.validate_host() {
  local value="$1"
  [[ -n "${value}" && "${value}" != -* && "${value}" != *[[:space:]]* ]] || \
    restore.die "${RESTORE_EXIT_USAGE}" "invalid remote host: ${value}"
}

restore.validate_storage_id() {
  local value="$1"
  [[ "${value}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || \
    restore.die "${RESTORE_EXIT_USAGE}" "invalid Proxmox storage ID: ${value}"
}

restore.validate_output() {
  local value="$1"
  shift
  local accepted
  for accepted in "$@"; do
    [[ "${value}" == "${accepted}" ]] && return 0
  done
  restore.die "${RESTORE_EXIT_USAGE}" "unsupported --output value: ${value}"
}

restore.validate_archive_name() {
  local path="$1"
  local base="${path##*/}"
  [[ "${base}" == vzdump-qemu-*.vma.zst || "${base}" == vzdump-qemu-*.vma ]] || \
    restore.die "${RESTORE_EXIT_USAGE}" "only QEMU .vma or .vma.zst archives are supported: ${base}"
  [[ "${base}" != vzdump-lxc-* ]] || \
    restore.die "${RESTORE_EXIT_USAGE}" "LXC backups are not supported: ${base}"
}

restore.archive_source_vm() {
  local base="${1##*/}"
  if [[ "${base}" =~ ^vzdump-qemu-([0-9]+)-.+\.vma(\.zst)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

restore.stage_lv_name() {
  local vm_id="$1"
  restore.validate_vm_id "${vm_id}"
  printf 'restore_stage_vm%s\n' "${vm_id}"
}

restore.stage_mountpoint() {
  local mount_root="$1"
  local vm_id="$2"
  restore.validate_vm_id "${vm_id}"
  printf '%s/%s\n' "${mount_root%/}" "${vm_id}"
}

restore.vm_lock_path() {
  local vm_id="$1"
  restore.validate_vm_id "${vm_id}"
  printf '%s/proxmox-restore-vm-%s.lock\n' "${RESTORE_LOCK_ROOT:-/run/lock}" "${vm_id}"
}

restore.require_commands() {
  local exit_code="$1"
  shift
  local command_name
  local -a missing=()
  for command_name in "$@"; do
    command -v "${command_name}" >/dev/null 2>&1 || missing+=("${command_name}")
  done
  ((${#missing[@]} == 0)) || \
    restore.die "${exit_code}" "missing required commands: ${missing[*]}"
}

restore.require_root() {
  ((EUID == 0)) || restore.die "${RESTORE_EXIT_PREFLIGHT}" "run as root on the target Proxmox node"
}

restore.require_proxmox() {
  restore.require_root
  [[ -d /etc/pve ]] || restore.die "${RESTORE_EXIT_PREFLIGHT}" "/etc/pve is unavailable; this is not an active Proxmox node"
  command -v pveversion >/dev/null 2>&1 || restore.die "${RESTORE_EXIT_PREFLIGHT}" "pveversion is unavailable"
  pveversion >/dev/null 2>&1 || restore.die "${RESTORE_EXIT_PREFLIGHT}" "pveversion failed"
}

restore.shell_quote() {
  local value="$1"
  printf '%q' "${value}"
}

restore.render_command() {
  local arg
  printf '+' >&2
  for arg in "$@"; do
    printf ' %q' "${arg}" >&2
  done
  printf '\n' >&2
}

restore.run() {
  restore.render_command "$@"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  "$@" >&2
}

restore.ensure_parent_dir() {
  local path="$1"
  local mode="${2:-0700}"
  local parent
  parent="$(dirname "${path}")"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    restore.render_command install -d -m "${mode}" "${parent}"
    return 0
  fi
  install -d -m "${mode}" "${parent}"
}

restore.ssh_options() {
  local -n destination="$1"
  local batch_mode="${2:-yes}"
  destination=(
    -p "${REMOTE_PORT}"
    -i "${IDENTITY}"
    -o "IdentitiesOnly=yes"
    -o "BatchMode=${batch_mode}"
    -o "ConnectTimeout=${CONNECT_TIMEOUT}"
    -o "UserKnownHostsFile=${KNOWN_HOSTS}"
    -o "StrictHostKeyChecking=yes"
  )
}

restore.rsync_ssh_command() {
  local port="$1"
  local identity="$2"
  local known_hosts="$3"
  local timeout="$4"
  printf 'ssh -p %q -i %q -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=%q -o UserKnownHostsFile=%q -o StrictHostKeyChecking=yes' \
    "${port}" "${identity}" "${timeout}" "${known_hosts}"
}

restore.known_host_has_fingerprint() {
  local host="$1"
  local port="$2"
  local known_hosts="$3"
  local fingerprint="$4"
  local lookup records keys actual result=1
  if [[ "${port}" == "22" ]]; then
    lookup="${host}"
  else
    lookup="[${host}]:${port}"
  fi
  records="$(mktemp)"
  keys="$(mktemp)"
  ssh-keygen -F "${lookup}" -f "${known_hosts}" >"${records}" 2>/dev/null || true
  awk '!/^#/' "${records}" >"${keys}"
  while IFS= read -r actual; do
    if [[ "${actual}" == "${fingerprint}" ]]; then
      result=0
      break
    fi
  done < <(ssh-keygen -lf "${keys}" -E sha256 2>/dev/null | awk '{print $2}')
  rm -f "${records}" "${keys}"
  return "${result}"
}

restore.confirm_exact() {
  local expected="$1"
  local reason="$2"
  local exit_code="${3:-${RESTORE_EXIT_COLLISION}}"
  local answer=""
  if [[ "${YES:-0}" == "1" ]]; then
    restore.log "confirmation accepted by --yes: ${reason}"
    return 0
  fi
  [[ -r /dev/tty ]] || restore.die "${exit_code}" "interactive confirmation required: ${reason}"
  printf '[%s] Type exactly "%s" to continue: ' "${RESTORE_COMPONENT:-restore}" "${expected}" >/dev/tty
  IFS= read -r answer </dev/tty || true
  [[ "${answer}" == "${expected}" ]] || restore.die "${exit_code}" "confirmation did not match"
}

restore.acquire_lock() {
  local vm_id="$1"
  local lock_path
  lock_path="$(restore.vm_lock_path "${vm_id}")"
  restore.ensure_parent_dir "${lock_path}" 0755
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    restore.log "dry-run lock: ${lock_path}"
    return 0
  fi
  exec {RESTORE_LOCK_FD}>"${lock_path}"
  flock -n "${RESTORE_LOCK_FD}" || restore.die "${RESTORE_EXIT_PREFLIGHT}" "another restore process holds ${lock_path}"
  RESTORE_LOCK_PATH="${lock_path}"
}

restore.parse_size_bytes() {
  local value="$1"
  local number suffix multiplier
  if [[ "${value}" =~ ^([0-9]+)([KkMmGgTt])([Ii]?[Bb])?$ ]]; then
    number="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    case "${suffix}" in
      K|k) multiplier=1024 ;;
      M|m) multiplier=1048576 ;;
      G|g) multiplier=1073741824 ;;
      T|t) multiplier=1099511627776 ;;
    esac
    printf '%s\n' "$((10#${number} * multiplier))"
    return 0
  fi
  if [[ "${value}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$((10#${value}))"
    return 0
  fi
  restore.die "${RESTORE_EXIT_USAGE}" "invalid size; use bytes or K/M/G/T suffix: ${value}"
}

restore.auto_stage_bytes() {
  local source_bytes="$1"
  local gib=1073741824
  local overhead=$((source_bytes / 20))
  ((overhead >= gib)) || overhead="${gib}"
  local wanted=$((source_bytes + overhead))
  printf '%s\n' "$((((wanted + gib - 1) / gib) * gib))"
}

restore.human_bytes() {
  local bytes="$1"
  awk -v bytes="${bytes}" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " "); i=1; value=bytes+0;
    while (value >= 1024 && i < 5) { value/=1024; i++ }
    if (i == 1) printf "%.0f %s", value, unit[i]; else printf "%.2f %s", value, unit[i]
  }'
}

restore.manifest_get() {
  local manifest="$1"
  local key="$2"
  [[ -f "${manifest}" ]] || return 1
  awk -F '\t' -v wanted="${key}" '$1 == wanted {sub(/^[^\t]*\t/, ""); print; found=1; exit} END {exit !found}' "${manifest}"
}

restore.manifest_put() {
  local manifest="$1"
  local key="$2"
  local value="$3"
  restore.validate_scalar "manifest ${key}" "${value}"
  local temp="${manifest}.tmp.$$"
  local parent
  parent="$(dirname "${manifest}")"
  install -d -m 0700 "${parent}"
  if [[ -f "${manifest}" ]]; then
    awk -F '\t' -v wanted="${key}" '$1 != wanted' "${manifest}" >"${temp}"
  else
    : >"${temp}"
  fi
  printf '%s\t%s\n' "${key}" "${value}" >>"${temp}"
  chmod 0600 "${temp}"
  mv -f "${temp}" "${manifest}"
}

restore.manifest_require() {
  local manifest="$1"
  local key="$2"
  local expected="$3"
  local actual=""
  actual="$(restore.manifest_get "${manifest}" "${key}" 2>/dev/null || true)"
  [[ "${actual}" == "${expected}" ]] || \
    restore.die "${RESTORE_EXIT_STORAGE}" "stage manifest mismatch for ${key}: expected ${expected}, found ${actual:-missing}"
}

restore.emit() {
  local output="$1"
  local human="$2"
  local path="${3:-}"
  local bytes="${4:-}"
  local sha256="${5:-}"
  local tsv="${6:-}"
  case "${output}" in
    human) [[ -n "${human}" ]] && restore.log "${human}" ;;
    path) printf '%s\n' "${path}" ;;
    bytes) printf '%s\n' "${bytes}" ;;
    sha256) printf '%s\n' "${sha256}" ;;
    tsv) printf '%s\n' "${tsv}" ;;
    *) restore.die "${RESTORE_EXIT_USAGE}" "unsupported output: ${output}" ;;
  esac
}
