#!/usr/bin/env bash
set -euo pipefail

RESTORE_COMPONENT="cli.rsync.fetch"
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

ACTION="inspect"
REMOTE_HOST=""
REMOTE_USER="root"
REMOTE_PORT="22"
REMOTE_PATH=""
IDENTITY="/root/.ssh/proxmox-restore-ed25519"
KNOWN_HOSTS="/root/.ssh/known_hosts"
HOST_KEY_FINGERPRINT=""
CONNECT_TIMEOUT="10"
RSYNC_TIMEOUT="0"
RSYNC_BWLIMIT_KBPS=""
DESTINATION_DIR=""
OUTPUT="human"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: cli/rsync/fetch.sh --action inspect|transfer --remote-host HOST --remote-path PATH [options]

Inspect or resumably fetch one QEMU VMA backup. Transfer uses no network
compression and verifies remote/local size and SHA-256 before succeeding.

Required:
  --remote-host HOST
  --remote-path PATH
  --destination-dir PATH            Required by --action transfer

Options:
  --action inspect|transfer         Default: inspect
  --remote-user USER                Default: root
  --remote-port PORT                Default: 22
  --identity PATH                   Default: /root/.ssh/proxmox-restore-ed25519
  --known-hosts PATH                Default: /root/.ssh/known_hosts
  --host-key-fingerprint SHA256:... Accepted shared connection pin
  --connect-timeout SECONDS         Default: 10
  --rsync-timeout SECONDS           Default: 0 (disabled)
  --rsync-bwlimit-kbps RATE
  --output human|path|bytes|sha256|json
  --dry-run
  --help

Examples:
  cli/rsync/fetch.sh --action inspect --remote-host 10.0.0.11 \
    --remote-path /backup/vzdump-qemu-200-date.vma.zst --output json
  cli/rsync/fetch.sh --action transfer --remote-host 10.0.0.11 \
    --remote-path /backup/vzdump-qemu-200-date.vma.zst \
    --destination-dir /mnt/pve-restore/200 --output path

Published runner:
  wget -qO- https://devs-guide.github.io/proxmox/cli/rsync/fetch.sh | \
    bash -s -- --action inspect --remote-host 10.0.0.11 \
      --remote-path /backup/vzdump-qemu-200-date.vma.zst
EOF
}

while (($#)); do
  case "$1" in
    --action) restore.require_flag_value "$1" "${2-}"; ACTION="$2"; shift 2 ;;
    --remote-host) restore.require_flag_value "$1" "${2-}"; REMOTE_HOST="$2"; shift 2 ;;
    --remote-user) restore.require_flag_value "$1" "${2-}"; REMOTE_USER="$2"; shift 2 ;;
    --remote-port) restore.require_flag_value "$1" "${2-}"; REMOTE_PORT="$2"; shift 2 ;;
    --remote-path) restore.require_flag_value "$1" "${2-}"; REMOTE_PATH="$2"; shift 2 ;;
    --identity) restore.require_flag_value "$1" "${2-}"; IDENTITY="$2"; shift 2 ;;
    --known-hosts) restore.require_flag_value "$1" "${2-}"; KNOWN_HOSTS="$2"; shift 2 ;;
    --host-key-fingerprint) restore.require_flag_value "$1" "${2-}"; HOST_KEY_FINGERPRINT="$2"; shift 2 ;;
    --connect-timeout) restore.require_flag_value "$1" "${2-}"; CONNECT_TIMEOUT="$2"; shift 2 ;;
    --rsync-timeout) restore.require_flag_value "$1" "${2-}"; RSYNC_TIMEOUT="$2"; shift 2 ;;
    --rsync-bwlimit-kbps) restore.require_flag_value "$1" "${2-}"; RSYNC_BWLIMIT_KBPS="$2"; shift 2 ;;
    --destination-dir) restore.require_flag_value "$1" "${2-}"; DESTINATION_DIR="$2"; shift 2 ;;
    --output) restore.require_flag_value "$1" "${2-}"; OUTPUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) restore.die "${RESTORE_EXIT_USAGE}" "unknown flag: $1" ;;
    *) restore.die "${RESTORE_EXIT_USAGE}" "positional arguments are not supported: $1" ;;
  esac
done

[[ "${ACTION}" == inspect || "${ACTION}" == transfer ]] || restore.die "${RESTORE_EXIT_USAGE}" "--action must be inspect or transfer"
[[ -n "${REMOTE_HOST}" ]] || restore.die "${RESTORE_EXIT_USAGE}" "--remote-host is required"
[[ -n "${REMOTE_PATH}" ]] || restore.die "${RESTORE_EXIT_USAGE}" "--remote-path is required"
[[ "${ACTION}" != transfer || -n "${DESTINATION_DIR}" ]] || restore.die "${RESTORE_EXIT_USAGE}" "--destination-dir is required for transfer"
[[ "${REMOTE_PATH}" == /* ]] || restore.die "${RESTORE_EXIT_USAGE}" "--remote-path must be absolute"
[[ -z "${DESTINATION_DIR}" || "${DESTINATION_DIR}" == /* ]] || restore.die "${RESTORE_EXIT_USAGE}" "--destination-dir must be absolute"
restore.validate_host "${REMOTE_HOST}"
restore.validate_remote_user "${REMOTE_USER}"
restore.validate_port "${REMOTE_PORT}"
restore.validate_positive_uint "--connect-timeout" "${CONNECT_TIMEOUT}"
restore.validate_uint "--rsync-timeout" "${RSYNC_TIMEOUT}"
[[ "${IDENTITY}" == /* ]] || restore.die "${RESTORE_EXIT_USAGE}" "--identity must be absolute"
[[ "${KNOWN_HOSTS}" == /* ]] || restore.die "${RESTORE_EXIT_USAGE}" "--known-hosts must be absolute"
[[ -z "${RSYNC_BWLIMIT_KBPS}" ]] || restore.validate_positive_uint "--rsync-bwlimit-kbps" "${RSYNC_BWLIMIT_KBPS}"
[[ -z "${HOST_KEY_FINGERPRINT}" || "${HOST_KEY_FINGERPRINT}" == SHA256:* ]] || \
  restore.die "${RESTORE_EXIT_USAGE}" "--host-key-fingerprint must start with SHA256:"
restore.validate_archive_name "${REMOTE_PATH}"
restore.validate_output "${OUTPUT}" human path bytes sha256 json
[[ -f "${IDENTITY}" && ! -L "${IDENTITY}" ]] || \
  restore.die "${RESTORE_EXIT_SSH}" "identity must be a regular non-symlink file: ${IDENTITY}"
[[ -f "${KNOWN_HOSTS}" && ! -L "${KNOWN_HOSTS}" ]] || \
  restore.die "${RESTORE_EXIT_SSH}" "known-hosts must be a regular non-symlink file: ${KNOWN_HOSTS}"
restore.require_commands "${RESTORE_EXIT_TRANSFER}" ssh sha256sum
if [[ "${OUTPUT}" == json ]]; then
  restore.require_commands "${RESTORE_EXIT_TRANSFER}" jq
fi
if [[ -n "${HOST_KEY_FINGERPRINT}" ]]; then
  restore.require_commands "${RESTORE_EXIT_SSH}" ssh-keygen
  restore.known_host_has_fingerprint "${REMOTE_HOST}" "${REMOTE_PORT}" "${KNOWN_HOSTS}" "${HOST_KEY_FINGERPRINT}" || \
    restore.die "${RESTORE_EXIT_SSH}" "known-hosts entry does not match ${HOST_KEY_FINGERPRINT}"
fi

REMOTE_BYTES=""
REMOTE_SHA256=""
REMOTE_BASENAME=""

inspect_remote() {
  local quoted_path quoted_script remote_script remote_command result
  local -a ssh_options=()
  quoted_path="$(restore.shell_quote "${REMOTE_PATH}")"
  remote_script="p=${quoted_path}; "
  remote_script+='if [ -L "$p" ]; then printf "restore-error:symlink\\n" >&2; exit 41; fi; '
  remote_script+='if [ ! -f "$p" ]; then printf "restore-error:not-regular\\n" >&2; exit 42; fi; '
  remote_script+='if [ ! -r "$p" ]; then printf "restore-error:not-readable\\n" >&2; exit 43; fi; '
  remote_script+='bytes=$(stat -Lc %s -- "$p") || exit 44; '
  remote_script+='sha=$(sha256sum -- "$p") || exit 45; sha=${sha%% *}; '
  remote_script+='base=${p##*/}; printf "%s\\n%s\\n%s\\n" "$bytes" "$sha" "$base"'
  quoted_script="$(restore.shell_quote "${remote_script}")"
  remote_command="bash -c ${quoted_script}"
  restore.ssh_options ssh_options yes
  restore.log "inspecting ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
  result="$(ssh "${ssh_options[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "${remote_command}")" || \
    restore.die "${RESTORE_EXIT_SSH}" "remote archive inspection failed"
  local extra=""
  {
    IFS= read -r REMOTE_BYTES || true
    IFS= read -r REMOTE_SHA256 || true
    IFS= read -r REMOTE_BASENAME || true
    IFS= read -r extra || true
  } <<<"${result}"
  [[ -z "${extra}" ]] || restore.die "${RESTORE_EXIT_TRANSFER}" "remote inspection returned unexpected metadata"
  [[ "${REMOTE_BYTES}" =~ ^[0-9]+$ && "${REMOTE_BYTES}" -gt 0 ]] || \
    restore.die "${RESTORE_EXIT_TRANSFER}" "remote inspection returned invalid byte count"
  [[ "${REMOTE_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] || \
    restore.die "${RESTORE_EXIT_TRANSFER}" "remote inspection returned invalid SHA-256"
  [[ "${REMOTE_BASENAME}" == "${REMOTE_PATH##*/}" ]] || \
    restore.die "${RESTORE_EXIT_TRANSFER}" "remote basename changed during inspection"
  restore.validate_archive_name "${REMOTE_BASENAME}"
}

emit_metadata() {
  local local_path="${1:-}"
  local human="remote archive ${REMOTE_BASENAME}: $(restore.human_bytes "${REMOTE_BYTES}"), sha256 ${REMOTE_SHA256}"
  local json=""
  if [[ "${OUTPUT}" == json ]]; then
    if [[ -n "${local_path}" ]]; then
      json="$(jq -cn \
        --arg bytes "${REMOTE_BYTES}" \
        --arg sha256 "${REMOTE_SHA256}" \
        --arg basename "${REMOTE_BASENAME}" \
        --arg path "${local_path}" \
        '{bytes: ($bytes | tonumber), sha256: $sha256, basename: $basename, path: $path}')"
    else
      json="$(jq -cn \
        --arg bytes "${REMOTE_BYTES}" \
        --arg sha256 "${REMOTE_SHA256}" \
        --arg basename "${REMOTE_BASENAME}" \
        '{bytes: ($bytes | tonumber), sha256: $sha256, basename: $basename}')"
    fi
  fi
  restore.emit "${OUTPUT}" "${human}" "${local_path:-${REMOTE_BASENAME}}" "${REMOTE_BYTES}" "${REMOTE_SHA256}" "${json}"
}

transfer_archive() {
  if [[ "${DRY_RUN}" == "1" && ! -e "${DESTINATION_DIR}" ]]; then
    : # The storage helper may only have planned this directory in the same dry run.
  elif [[ ! -d "${DESTINATION_DIR}" || -L "${DESTINATION_DIR}" ]]; then
    restore.die "${RESTORE_EXIT_TRANSFER}" "destination must be an existing non-symlink directory: ${DESTINATION_DIR}"
  fi
  local local_path="${DESTINATION_DIR%/}/${REMOTE_BASENAME}"
  if [[ -L "${local_path}" ]]; then
    restore.die "${RESTORE_EXIT_TRANSFER}" "refusing symlink destination: ${local_path}"
  fi

  local rsync_ssh
  local -a rsync_command=(
    rsync
    --archive
    --partial
    --append-verify
    --secluded-args
    --info=progress2
  )
  rsync_ssh="$(restore.rsync_ssh_command "${REMOTE_PORT}" "${IDENTITY}" "${KNOWN_HOSTS}" "${CONNECT_TIMEOUT}")"
  rsync_command+=(--rsh "${rsync_ssh}")
  ((10#${RSYNC_TIMEOUT} == 0)) || rsync_command+=(--timeout "${RSYNC_TIMEOUT}")
  [[ -z "${RSYNC_BWLIMIT_KBPS}" ]] || rsync_command+=(--bwlimit "${RSYNC_BWLIMIT_KBPS}")
  rsync_command+=("${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}" "${DESTINATION_DIR%/}/")

  restore.log "transferring without network compression; partial data is resumable"
  restore.run "${rsync_command[@]}" || restore.die "${RESTORE_EXIT_TRANSFER}" "rsync transfer failed; partial data was retained"
  if [[ "${DRY_RUN}" == "1" ]]; then
    emit_metadata "${local_path}"
    return 0
  fi

  [[ -f "${local_path}" && ! -L "${local_path}" ]] || \
    restore.die "${RESTORE_EXIT_TRANSFER}" "rsync did not produce the expected regular file: ${local_path}"
  local local_bytes local_sha initial_bytes initial_sha
  initial_bytes="${REMOTE_BYTES}"
  initial_sha="${REMOTE_SHA256}"
  local_bytes="$(stat -Lc %s -- "${local_path}")"
  local_sha="$(sha256sum -- "${local_path}")"
  local_sha="${local_sha%% *}"
  inspect_remote
  [[ "${REMOTE_BYTES}" == "${initial_bytes}" && "${REMOTE_SHA256}" == "${initial_sha}" ]] || \
    restore.die "${RESTORE_EXIT_INTEGRITY}" "remote archive changed during transfer"
  [[ "${local_bytes}" == "${REMOTE_BYTES}" ]] || \
    restore.die "${RESTORE_EXIT_INTEGRITY}" "size mismatch: remote ${REMOTE_BYTES}, local ${local_bytes}"
  [[ "${local_sha}" == "${REMOTE_SHA256}" ]] || \
    restore.die "${RESTORE_EXIT_INTEGRITY}" "SHA-256 mismatch after transfer"
  restore.log "remote/local size and SHA-256 match"
  emit_metadata "${local_path}"
}

inspect_remote
case "${ACTION}" in
  inspect) emit_metadata ;;
  transfer)
    restore.require_commands "${RESTORE_EXIT_TRANSFER}" rsync stat
    transfer_archive
    ;;
esac
