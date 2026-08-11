#!/usr/bin/env bash
set -euo pipefail

RESTORE_COMPONENT="cli.ssh.sync"
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

ACTION="check"
REMOTE_HOST=""
REMOTE_USER="root"
REMOTE_PORT="22"
IDENTITY="/root/.ssh/proxmox-restore-ed25519"
KNOWN_HOSTS="/root/.ssh/known_hosts"
HOST_KEY_FINGERPRINT=""
CONNECT_TIMEOUT="10"
OUTPUT="human"
DRY_RUN=0
KEY_ROTATION=0
YES=0
ROTATION_TEMP_IDENTITY=""
declare -a OLD_KEY_BLOBS=()

usage() {
  cat <<'EOF'
Usage: cli/ssh/sync.sh --action setup|check --remote-host HOST [options]

Establish or verify the dedicated passwordless SSH identity used by VM restore.
The setup action may prompt for the remote password. Passwords are never flags.

Required:
  --remote-host HOST

Options:
  --action setup|check             Default: check
  --remote-user USER               Default: root
  --remote-port PORT               Default: 22
  --identity PATH                  Default: /root/.ssh/proxmox-restore-ed25519
  --known-hosts PATH               Default: /root/.ssh/known_hosts
  --host-key-fingerprint SHA256:... Pin the remote host key during setup
  --connect-timeout SECONDS        Default: 10
  --output human|path|tsv          Default: human
  --key-rotation                   Install/verify a fresh key, then remove old keys
  --yes                            Required confirmation for --key-rotation
  --dry-run                        Print mutations without performing them
  --help

Examples:
  cli/ssh/sync.sh --action setup --remote-host 10.0.0.11
  cli/ssh/sync.sh --action setup --remote-host 10.0.0.11 \
    --key-rotation --yes
  cli/ssh/sync.sh --action check --remote-host 10.0.0.11 --output tsv

Published runner:
  wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh | \
    bash -s -- --action setup --remote-host 10.0.0.11
  wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh | \
    bash -s -- --action setup --remote-host 10.0.0.11 --key-rotation --yes
EOF
}

while (($#)); do
  case "$1" in
    --action) restore.require_flag_value "$1" "${2-}"; ACTION="$2"; shift 2 ;;
    --remote-host) restore.require_flag_value "$1" "${2-}"; REMOTE_HOST="$2"; shift 2 ;;
    --remote-user) restore.require_flag_value "$1" "${2-}"; REMOTE_USER="$2"; shift 2 ;;
    --remote-port) restore.require_flag_value "$1" "${2-}"; REMOTE_PORT="$2"; shift 2 ;;
    --identity) restore.require_flag_value "$1" "${2-}"; IDENTITY="$2"; shift 2 ;;
    --known-hosts) restore.require_flag_value "$1" "${2-}"; KNOWN_HOSTS="$2"; shift 2 ;;
    --host-key-fingerprint) restore.require_flag_value "$1" "${2-}"; HOST_KEY_FINGERPRINT="$2"; shift 2 ;;
    --connect-timeout) restore.require_flag_value "$1" "${2-}"; CONNECT_TIMEOUT="$2"; shift 2 ;;
    --output) restore.require_flag_value "$1" "${2-}"; OUTPUT="$2"; shift 2 ;;
    --key-rotation) KEY_ROTATION=1; shift ;;
    --yes) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) restore.die "${RESTORE_EXIT_USAGE}" "unknown flag: $1" ;;
    *) restore.die "${RESTORE_EXIT_USAGE}" "positional arguments are not supported: $1" ;;
  esac
done

[[ "${ACTION}" == setup || "${ACTION}" == check ]] || restore.die "${RESTORE_EXIT_USAGE}" "--action must be setup or check"
[[ -n "${REMOTE_HOST}" ]] || restore.die "${RESTORE_EXIT_USAGE}" "--remote-host is required"
restore.validate_host "${REMOTE_HOST}"
restore.validate_remote_user "${REMOTE_USER}"
restore.validate_port "${REMOTE_PORT}"
restore.validate_positive_uint "--connect-timeout" "${CONNECT_TIMEOUT}"
restore.validate_output "${OUTPUT}" human path tsv
[[ "${IDENTITY}" == /* ]] || restore.die "${RESTORE_EXIT_USAGE}" "--identity must be absolute"
[[ "${KNOWN_HOSTS}" == /* ]] || restore.die "${RESTORE_EXIT_USAGE}" "--known-hosts must be absolute"
[[ -z "${HOST_KEY_FINGERPRINT}" || "${HOST_KEY_FINGERPRINT}" == SHA256:* ]] || \
  restore.die "${RESTORE_EXIT_USAGE}" "--host-key-fingerprint must start with SHA256:"
if ((KEY_ROTATION)); then
  [[ "${ACTION}" == setup ]] || restore.die "${RESTORE_EXIT_USAGE}" "--key-rotation requires --action setup"
  ((YES)) || restore.die "${RESTORE_EXIT_USAGE}" "--key-rotation requires --yes"
elif ((YES)); then
  restore.die "${RESTORE_EXIT_USAGE}" "--yes is only valid with --key-rotation"
fi

SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
PUBLIC_KEY="${IDENTITY}.pub"
[[ ! -L "${IDENTITY}" && ! -L "${PUBLIC_KEY}" && ! -L "${KNOWN_HOSTS}" ]] || \
  restore.die "${RESTORE_EXIT_SSH}" "identity and host-key files must not be symlinks"

ensure_identity() {
  restore.require_commands "${RESTORE_EXIT_SSH}" ssh ssh-keygen
  if [[ -e "${IDENTITY}" && ! -f "${IDENTITY}" ]]; then
    restore.die "${RESTORE_EXIT_SSH}" "identity exists but is not a regular file: ${IDENTITY}"
  fi

  if [[ ! -f "${IDENTITY}" ]]; then
    restore.log "creating dedicated ED25519 identity: ${IDENTITY}"
    restore.ensure_parent_dir "${IDENTITY}" 0700
    restore.run ssh-keygen -q -t ed25519 -N '' -C "proxmox-restore@$(hostname -s)" -f "${IDENTITY}"
  else
    restore.log "reusing existing identity: ${IDENTITY}"
  fi

  if [[ "${DRY_RUN}" == "1" && ! -f "${IDENTITY}" ]]; then
    return 0
  fi
  local derived_public
  derived_public="$(ssh-keygen -y -f "${IDENTITY}")" || restore.die "${RESTORE_EXIT_SSH}" "could not derive the public key from ${IDENTITY}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    restore.render_command chmod 0600 "${IDENTITY}"
    if [[ ! -f "${PUBLIC_KEY}" ]]; then
      restore.log "dry-run: would derive ${PUBLIC_KEY} from the selected private identity"
    elif [[ "$(awk '{print $1 " " $2; exit}' "${PUBLIC_KEY}")" != "${derived_public}" ]]; then
      restore.die "${RESTORE_EXIT_SSH}" "existing public key does not match the selected private identity: ${PUBLIC_KEY}"
    else
      restore.render_command chmod 0644 "${PUBLIC_KEY}"
    fi
    return 0
  fi
  chmod 0600 "${IDENTITY}"
  if [[ ! -f "${PUBLIC_KEY}" ]]; then
    local public_temp="${PUBLIC_KEY}.tmp.$$"
    printf '%s proxmox-restore@%s\n' "${derived_public}" "$(hostname -s)" >"${public_temp}"
    mv -f "${public_temp}" "${PUBLIC_KEY}"
  elif [[ "$(awk '{print $1 " " $2; exit}' "${PUBLIC_KEY}")" != "${derived_public}" ]]; then
    restore.die "${RESTORE_EXIT_SSH}" "existing public key does not match the selected private identity: ${PUBLIC_KEY}"
  fi
  chmod 0644 "${PUBLIC_KEY}"
}

known_host_lookup() {
  if [[ "${REMOTE_PORT}" == "22" ]]; then
    printf '%s\n' "${REMOTE_HOST}"
  else
    printf '[%s]:%s\n' "${REMOTE_HOST}" "${REMOTE_PORT}"
  fi
}

fingerprint_file_contains() {
  local key_file="$1"
  local expected="$2"
  ssh-keygen -lf "${key_file}" -E sha256 2>/dev/null | awk '{print $2}' | grep -Fxq -- "${expected}"
}

pin_host_key() {
  restore.require_commands "${RESTORE_EXIT_SSH}" ssh-keyscan ssh-keygen
  restore.ensure_parent_dir "${KNOWN_HOSTS}" 0700
  local lookup existing scan selected line_file
  lookup="$(known_host_lookup)"
  existing="$(mktemp)"
  scan="$(mktemp)"
  selected="$(mktemp)"
  line_file="$(mktemp)"
  if [[ -f "${KNOWN_HOSTS}" ]]; then
    ssh-keygen -F "${lookup}" -f "${KNOWN_HOSTS}" >"${existing}" 2>/dev/null || true
    if [[ -s "${existing}" ]]; then
      awk '!/^#/' "${existing}" >"${selected}"
      if fingerprint_file_contains "${selected}" "${HOST_KEY_FINGERPRINT}"; then
        restore.log "known host already matches pinned fingerprint"
        if [[ "${DRY_RUN}" == "1" ]]; then
          restore.render_command chmod 0600 "${KNOWN_HOSTS}"
        else
          chmod 0600 "${KNOWN_HOSTS}"
        fi
        rm -f "${existing}" "${scan}" "${selected}" "${line_file}"
        return 0
      fi
      restore.die "${RESTORE_EXIT_SSH}" "existing host key for ${lookup} does not match the pinned fingerprint; refusing replacement"
    fi
  fi

  restore.log "scanning and verifying host key fingerprint for ${lookup}"
  if ! ssh-keyscan -p "${REMOTE_PORT}" -T "${CONNECT_TIMEOUT}" "${REMOTE_HOST}" >"${scan}" 2>/dev/null; then
    restore.die "${RESTORE_EXIT_SSH}" "ssh-keyscan failed for ${lookup}"
  fi

  : >"${selected}"
  while IFS= read -r line; do
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    printf '%s\n' "${line}" >"${line_file}"
    if fingerprint_file_contains "${line_file}" "${HOST_KEY_FINGERPRINT}"; then
      printf '%s\n' "${line}" >>"${selected}"
    fi
  done <"${scan}"
  [[ -s "${selected}" ]] || restore.die "${RESTORE_EXIT_SSH}" "no scanned key matched ${HOST_KEY_FINGERPRINT}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    restore.log "dry-run: would add the verified host key to ${KNOWN_HOSTS}"
    rm -f "${existing}" "${scan}" "${selected}" "${line_file}"
    return 0
  fi
  touch "${KNOWN_HOSTS}"
  chmod 0600 "${KNOWN_HOSTS}"
  while IFS= read -r line; do
    grep -Fqx -- "${line}" "${KNOWN_HOSTS}" || printf '%s\n' "${line}" >>"${KNOWN_HOSTS}"
  done <"${selected}"
  rm -f "${existing}" "${scan}" "${selected}" "${line_file}"
}

check_passwordless() {
  [[ -f "${IDENTITY}" ]] || restore.die "${RESTORE_EXIT_SSH}" "identity not found: ${IDENTITY}; run --action setup"
  [[ -f "${KNOWN_HOSTS}" ]] || restore.die "${RESTORE_EXIT_SSH}" "known-hosts file not found: ${KNOWN_HOSTS}; run --action setup"
  if [[ -n "${HOST_KEY_FINGERPRINT}" ]]; then
    restore.require_commands "${RESTORE_EXIT_SSH}" ssh-keygen
    restore.known_host_has_fingerprint "${REMOTE_HOST}" "${REMOTE_PORT}" "${KNOWN_HOSTS}" "${HOST_KEY_FINGERPRINT}" || \
      restore.die "${RESTORE_EXIT_SSH}" "known-hosts entry does not match ${HOST_KEY_FINGERPRINT}"
  fi
  local -a ssh_options=()
  restore.ssh_options ssh_options yes
  restore.log "checking BatchMode SSH access to ${SSH_TARGET}"
  ssh "${ssh_options[@]}" "${SSH_TARGET}" /usr/bin/printf 'proxmox-restore-ssh-ok\n' >/dev/null || \
    restore.die "${RESTORE_EXIT_SSH}" "passwordless SSH check failed for ${SSH_TARGET}"
}

setup_passwordless() {
  ensure_identity
  restore.ensure_parent_dir "${KNOWN_HOSTS}" 0700

  local strict_host_key="ask"
  if [[ -n "${HOST_KEY_FINGERPRINT}" ]]; then
    pin_host_key
    strict_host_key="yes"
  elif [[ -f "${KNOWN_HOSTS}" && "${DRY_RUN}" != "1" ]]; then
    chmod 0600 "${KNOWN_HOSTS}"
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    restore.render_command ssh-copy-id -i "${PUBLIC_KEY}" -p "${REMOTE_PORT}" \
      -o "ConnectTimeout=${CONNECT_TIMEOUT}" -o "UserKnownHostsFile=${KNOWN_HOSTS}" \
      -o "StrictHostKeyChecking=${strict_host_key}" "${SSH_TARGET}"
    restore.log "dry-run complete; passwordless access was not changed or checked"
    return 0
  fi

  restore.require_commands "${RESTORE_EXIT_SSH}" ssh-copy-id
  touch "${KNOWN_HOSTS}"
  chmod 0600 "${KNOWN_HOSTS}"
  restore.log "installing only ${PUBLIC_KEY}; an initial password prompt may follow"
  ssh-copy-id -i "${PUBLIC_KEY}" -p "${REMOTE_PORT}" \
    -o "ConnectTimeout=${CONNECT_TIMEOUT}" \
    -o "UserKnownHostsFile=${KNOWN_HOSTS}" \
    -o "StrictHostKeyChecking=${strict_host_key}" \
    "${SSH_TARGET}" >&2 || restore.die "${RESTORE_EXIT_SSH}" "public-key installation failed"
  check_passwordless
}

append_old_key_blob() {
  local public_material="$1"
  local blob existing
  blob="${public_material#* }"
  blob="${blob%% *}"
  [[ "${blob}" =~ ^[a-zA-Z0-9+/]+={0,3}$ ]] || return 0
  for existing in "${OLD_KEY_BLOBS[@]}"; do
    [[ "${existing}" == "${blob}" ]] && return 0
  done
  OLD_KEY_BLOBS+=("${blob}")
}

collect_old_key_blobs() {
  local public_material=""
  OLD_KEY_BLOBS=()

  if [[ -f "${IDENTITY}" ]]; then
    if public_material="$(ssh-keygen -y -f "${IDENTITY}" 2>/dev/null)"; then
      append_old_key_blob "${public_material}"
    else
      restore.warn "could not derive the old public key from ${IDENTITY}; continuing with fresh rotation"
    fi
  fi
  if [[ -f "${PUBLIC_KEY}" ]]; then
    public_material="$(awk 'NF >= 2 {print $1 " " $2; exit}' "${PUBLIC_KEY}")"
    if [[ -n "${public_material}" ]]; then
      append_old_key_blob "${public_material}"
    else
      restore.warn "could not parse the old public key ${PUBLIC_KEY}; continuing with fresh rotation"
    fi
  fi
}

cleanup_rotation_temp() {
  [[ -n "${ROTATION_TEMP_IDENTITY}" ]] || return 0
  rm -f "${ROTATION_TEMP_IDENTITY}" "${ROTATION_TEMP_IDENTITY}.pub"
}

remove_remote_old_keys() {
  ((${#OLD_KEY_BLOBS[@]} > 0)) || {
    restore.log "no valid old public keys were found for remote removal"
    return 0
  }

  local -a ssh_options=()
  restore.ssh_options ssh_options yes
  restore.log "removing only the previous dedicated key material from ${SSH_TARGET}:~/.ssh/authorized_keys"
  ssh "${ssh_options[@]}" "${SSH_TARGET}" bash -s -- "${OLD_KEY_BLOBS[@]}" <<'REMOTE_KEY_CLEANUP'
set -eu
authorized_keys="${PROXMOX_RESTORE_AUTHORIZED_KEYS:-${HOME}/.ssh/authorized_keys}"
[[ -e "${authorized_keys}" ]] || exit 0
[[ -f "${authorized_keys}" && ! -L "${authorized_keys}" ]] || {
  printf '[cli.ssh.sync][error] remote authorized_keys is not a regular non-symlink file\n' >&2
  exit 20
}
temporary="${authorized_keys}.proxmox-restore.$$"
trap 'rm -f "${temporary}"' EXIT HUP INT TERM
awk '
  BEGIN {
    for (i = 1; i < ARGC - 1; i++) {
      old[ARGV[i]] = 1
      ARGV[i] = ""
    }
  }
  {
    remove = 0
    for (i = 1; i < NF; i++) {
      if ($i ~ /^(ssh-|ecdsa-|sk-)/ && $(i + 1) in old) {
        remove = 1
        break
      }
    }
    if (!remove) print
  }
' "$@" "${authorized_keys}" >"${temporary}"
chmod 0600 "${temporary}"
mv -f "${temporary}" "${authorized_keys}"
trap - EXIT HUP INT TERM
REMOTE_KEY_CLEANUP
}

rotate_passwordless() {
  local original_identity="${IDENTITY}"
  local original_public="${PUBLIC_KEY}"
  local new_identity="${original_identity}.rotation-new.$$"
  local new_public="${new_identity}.pub"
  local old_identity="${original_identity}.rotation-old.$$"
  local old_public="${original_public}.rotation-old.$$"
  local old_identity_saved=0
  local old_public_saved=0

  [[ ! -e "${old_identity}" && ! -e "${old_public}" ]] || \
    restore.die "${RESTORE_EXIT_SSH}" "rotation backup path already exists; retry the command"
  collect_old_key_blobs
  ROTATION_TEMP_IDENTITY="${new_identity}"
  trap cleanup_rotation_temp EXIT

  IDENTITY="${new_identity}"
  PUBLIC_KEY="${new_public}"
  restore.log "generating and verifying a fresh dedicated key before replacing the current pair"
  setup_passwordless

  IDENTITY="${original_identity}"
  PUBLIC_KEY="${original_public}"
  if ((DRY_RUN)); then
    restore.log "dry-run: would atomically replace ${original_identity} and remove matching old remote keys after verification"
    cleanup_rotation_temp
    trap - EXIT
    return 0
  fi

  if [[ -e "${original_identity}" ]]; then
    if ! mv "${original_identity}" "${old_identity}"; then
      restore.die "${RESTORE_EXIT_SSH}" "could not preserve the old private identity before rotation"
    fi
    old_identity_saved=1
  fi
  if [[ -e "${original_public}" ]]; then
    if ! mv "${original_public}" "${old_public}"; then
      ((old_identity_saved)) && mv "${old_identity}" "${original_identity}"
      restore.die "${RESTORE_EXIT_SSH}" "could not preserve the old public identity before rotation"
    fi
    old_public_saved=1
  fi
  if ! mv "${new_identity}" "${original_identity}"; then
    ((old_identity_saved)) && mv "${old_identity}" "${original_identity}"
    ((old_public_saved)) && mv "${old_public}" "${original_public}"
    restore.die "${RESTORE_EXIT_SSH}" "could not install the rotated private identity"
  fi
  if ! mv "${new_public}" "${original_public}"; then
    rm -f "${original_identity}"
    ((old_identity_saved)) && mv "${old_identity}" "${original_identity}"
    ((old_public_saved)) && mv "${old_public}" "${original_public}"
    restore.die "${RESTORE_EXIT_SSH}" "could not install the rotated public identity"
  fi
  chmod 0600 "${original_identity}"
  chmod 0644 "${original_public}"
  ROTATION_TEMP_IDENTITY=""

  check_passwordless
  if ! remove_remote_old_keys; then
    restore.error "new key is active, but remote old-key cleanup failed; retained local recovery files: ${old_identity}, ${old_public}"
    exit "${RESTORE_EXIT_SSH}"
  fi

  ((old_identity_saved)) && rm -f "${old_identity}"
  ((old_public_saved)) && rm -f "${old_public}"
  trap - EXIT
  restore.log "key rotation completed; the previous local pair and matching remote keys were removed"
}

case "${ACTION}" in
  setup)
    if ((KEY_ROTATION)); then
      rotate_passwordless
    else
      setup_passwordless
    fi
    ;;
  check) check_passwordless ;;
esac

case "${OUTPUT}" in
  human) restore.log "SSH ${ACTION} completed for ${SSH_TARGET}" ;;
  path) printf '%s\n' "${IDENTITY}" ;;
  tsv) printf 'host\t%s\tuser\t%s\tport\t%s\tidentity\t%s\tknown_hosts\t%s\n' \
    "${REMOTE_HOST}" "${REMOTE_USER}" "${REMOTE_PORT}" "${IDENTITY}" "${KNOWN_HOSTS}" ;;
esac
