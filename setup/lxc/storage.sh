#!/usr/bin/env bash
## Prepare transfer roots and map a Samba service identity onto Proxmox bind storage.
## Run on the Proxmox host after the LXC and operator-managed mountpoint exist.

set -euo pipefail

log()       { printf '[setup.lxc.storage] %s\n' "$*" >&2; }
log.error() { printf '[setup.lxc.storage][error] %s\n' "$*" >&2; }
die()       { log.error "$*"; exit 1; }

MODE="${1:-${PROXMOX_LXC_STORAGE_MODE:-preflight}}"
PROFILE_INPUT="${PROXMOX_LXC_STORAGE_PROFILE:-}"
CTID="${PROXMOX_LXC_STORAGE_CTID:-${PROXMOX_CTID:-}}"
MOUNT_SLOT="${PROXMOX_LXC_STORAGE_MOUNT_SLOT:-}"
SERVICE_UID="${PROXMOX_LXC_STORAGE_SERVICE_UID:-2000}"
SERVICE_GID="${PROXMOX_LXC_STORAGE_SERVICE_GID:-2000}"
SERVICE_USER="${PROXMOX_LXC_STORAGE_SERVICE_USER:-}"
SERVICE_GROUP="${PROXMOX_LXC_STORAGE_SERVICE_GROUP:-}"
TRANSFER_USER="${PROXMOX_LXC_STORAGE_TRANSFER_USER:-}"
CONTAINER_PATH="${PROXMOX_LXC_STORAGE_CONTAINER_PATH:-}"
EXCLUDE_CONTAINER_PATH="${PROXMOX_LXC_STORAGE_EXCLUDE_CONTAINER_PATH:-}"
FACTS_DIR="${PROXMOX_LXC_STORAGE_FACTS_DIR:-/etc/ansible/proxmox/facts}"
SELECTION_PATH="${PROXMOX_LXC_STORAGE_SELECTION_PATH:-${FACTS_DIR}/lxc.storage.selection.yml}"
LXC_CONFIG_DIR="${PROXMOX_LXC_STORAGE_LXC_CONFIG_DIR:-/etc/pve/lxc}"
SUBUID_PATH="${PROXMOX_LXC_STORAGE_SUBUID_PATH:-/etc/subuid}"
SUBGID_PATH="${PROXMOX_LXC_STORAGE_SUBGID_PATH:-/etc/subgid}"
INTERACTIVE="${PROXMOX_LXC_STORAGE_INTERACTIVE:-1}"
OPEN_TTY=0
RECONCILE=0
PREPARE_TRANSFER=0
STORAGE_PROFILE="mount-root"
SELECTED_SOURCE=""
SELECTED_TARGET=""
SELECTED_PATH=""
SELECTED_CONTAINER_PATH=""
TRANSFER_UID=""
TRANSFER_GID=""
ROOT_UID=0
ROOT_GID=0
EXCLUDED_PATH=""

is.true() {
  case "${1,,}" in 1|true|yes|y|on) return 0 ;; *) return 1 ;; esac
}

open.tty() {
  [[ -r /dev/tty ]] || return 1
  exec 3<>/dev/tty
  OPEN_TTY=1
}

prompt.tty() {
  local prompt="$1" default="${2:-}" answer=""
  if [[ -n "${default}" ]]; then printf '%s [%s]: ' "${prompt}" "${default}" >&3; else printf '%s: ' "${prompt}" >&3; fi
  read -r -u 3 answer || true
  printf '%s\n' "${answer:-${default}}"
}

menu.tty() {
  local prompt="$1"; shift
  local -a options=("$@")
  local answer i
  while true; do
    printf '%s\n' "${prompt}" >&3
    for i in "${!options[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${options[$i]}" >&3; done
    printf 'Select option: ' >&3
    read -r -u 3 answer || true
    [[ "${answer}" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#options[@]})) && { printf '%s\n' "${answer}"; return; }
  done
}

require.host() {
  [[ "$(id -u)" -eq 0 ]] || die 'Run as root on the Proxmox host.'
  command -v pveversion >/dev/null 2>&1 || die 'pveversion was not found.'
  command -v pct >/dev/null 2>&1 || die 'pct was not found.'
  command -v setfacl >/dev/null 2>&1 || die 'setfacl was not found; install the acl package.'
  command -v getfacl >/dev/null 2>&1 || die 'getfacl was not found; install the acl package.'
  command -v realpath >/dev/null 2>&1 || die 'realpath was not found.'
  command -v mountpoint >/dev/null 2>&1 || die 'mountpoint was not found.'
  case "${MODE}" in
    preflight|apply|apply-recursive|verify) ;;
    *) die 'Mode must be preflight, apply, apply-recursive, or verify.' ;;
  esac

  if [[ -n "${CONTAINER_PATH}" ]]; then
    RECONCILE=1
    [[ -n "${SERVICE_USER}" && -n "${SERVICE_GROUP}" && -n "${TRANSFER_USER}" ]] \
      || die 'Destination reconciliation requires service user, service group, and transfer user.'
    [[ "${CONTAINER_PATH}" == /* && "${CONTAINER_PATH}" != / ]] \
      || die 'The reconciliation container path must be an absolute non-root path.'
    CONTAINER_PATH="${CONTAINER_PATH%/}"
    case "/${CONTAINER_PATH#/}/" in
      *'/../'*|*'/./'*|*'//'*) die 'The reconciliation container path must be canonical.' ;;
    esac
    if [[ -n "${EXCLUDE_CONTAINER_PATH}" ]]; then
      [[ "${EXCLUDE_CONTAINER_PATH}" == /* && "${EXCLUDE_CONTAINER_PATH}" != / ]] \
        || die 'The excluded container path must be an absolute non-root path.'
      EXCLUDE_CONTAINER_PATH="${EXCLUDE_CONTAINER_PATH%/}"
      case "/${EXCLUDE_CONTAINER_PATH#/}/" in
        *'/../'*|*'/./'*|*'//'*) die 'The excluded container path must be canonical.' ;;
      esac
      case "${EXCLUDE_CONTAINER_PATH}" in
        "${CONTAINER_PATH}"/*) ;;
        *) die 'The excluded container path must be a descendant of the reconciliation path.' ;;
      esac
    fi
    case "${PROFILE_INPUT:-destination-reconciliation}" in
      destination-reconciliation)
        STORAGE_PROFILE=destination-reconciliation
        ;;
      transfer-destination)
        STORAGE_PROFILE=transfer-destination
        PREPARE_TRANSFER=1
        ;;
      *)
        die 'PROXMOX_LXC_STORAGE_PROFILE must be destination-reconciliation or transfer-destination.'
        ;;
    esac
  elif [[ -n "${SERVICE_USER}${SERVICE_GROUP}${TRANSFER_USER}${EXCLUDE_CONTAINER_PATH}" ]]; then
    die 'Named identities and exclusions require PROXMOX_LXC_STORAGE_CONTAINER_PATH.'
  elif [[ -n "${PROFILE_INPUT}" ]]; then
    die 'PROXMOX_LXC_STORAGE_PROFILE requires PROXMOX_LXC_STORAGE_CONTAINER_PATH.'
  fi

  if [[ "${MODE}" == verify && ${RECONCILE} -ne 1 ]]; then
    die 'Verify mode requires destination reconciliation inputs.'
  fi
  [[ "${SERVICE_UID}" =~ ^[0-9]+$ && "${SERVICE_GID}" =~ ^[0-9]+$ ]] \
    || die 'Service UID/GID must be numeric.'
}

select.reconciliation.path() {
  local -a mounts=("$@")
  local line slot remainder source target selected="" selected_length=-1
  local relative candidate lexical resolved root_real

  for line in "${mounts[@]}"; do
    slot="${line%%|*}"
    remainder="${line#*|}"
    source="${remainder%%|*}"
    target="${line##*|}"
    [[ -z "${MOUNT_SLOT}" || "${slot}" == "${MOUNT_SLOT}" ]] || continue
    case "${CONTAINER_PATH}" in
      "${target}"|"${target}"/*)
        if ((${#target} > selected_length)); then
          selected="${line}"
          selected_length=${#target}
        fi
        ;;
    esac
  done
  [[ -n "${selected}" ]] || die "No selected bind mount contains ${CONTAINER_PATH}."

  MOUNT_SLOT="${selected%%|*}"
  remainder="${selected#*|}"
  SELECTED_SOURCE="${remainder%%|*}"
  SELECTED_TARGET="${selected##*|}"
  [[ ! -L "${SELECTED_SOURCE}" ]] || die 'The selected bind source must not be a symlink.'
  mountpoint -q -- "${SELECTED_SOURCE}" \
    || die "The selected bind source is not an active mountpoint: ${SELECTED_SOURCE}. This runner never mounts storage."

  root_real="$(realpath -e -- "${SELECTED_SOURCE}")" || die 'Unable to resolve the selected bind source.'
  relative="${CONTAINER_PATH#"${SELECTED_TARGET}"}"
  relative="${relative#/}"
  candidate="${root_real}${relative:+/${relative}}"
  [[ -d "${candidate}" && ! -L "${candidate}" ]] \
    || die "The selected destination must be an existing real directory: ${CONTAINER_PATH}."
  lexical="$(realpath -m -- "${candidate}")"
  resolved="$(realpath -e -- "${candidate}")"
  [[ "${lexical}" == "${resolved}" ]] || die 'The selected destination contains a symlinked path component.'
  case "${resolved}" in
    "${root_real}"|"${root_real}"/*) ;;
    *) die 'The selected destination escapes the bind source.' ;;
  esac
  [[ "$(stat -c '%d' "${root_real}")" == "$(stat -c '%d' "${resolved}")" ]] \
    || die 'The selected destination crosses onto another filesystem.'
  SELECTED_PATH="${resolved}"
  SELECTED_CONTAINER_PATH="${CONTAINER_PATH}"

  if [[ -n "${EXCLUDE_CONTAINER_PATH}" ]]; then
    relative="${EXCLUDE_CONTAINER_PATH#"${SELECTED_TARGET}"}"
    relative="${relative#/}"
    candidate="${root_real}${relative:+/${relative}}"
    [[ -d "${candidate}" && ! -L "${candidate}" ]] \
      || die "The excluded destination must be an existing real directory: ${EXCLUDE_CONTAINER_PATH}."
    lexical="$(realpath -m -- "${candidate}")"
    resolved="$(realpath -e -- "${candidate}")"
    [[ "${lexical}" == "${resolved}" ]] || die 'The excluded destination contains a symlinked path component.'
    case "${resolved}" in
      "${SELECTED_PATH}"/*) ;;
      *) die 'The excluded destination escapes the selected reconciliation path.' ;;
    esac
    [[ "$(stat -c '%d' "${root_real}")" == "$(stat -c '%d' "${resolved}")" ]] \
      || die 'The excluded destination crosses onto another filesystem.'
    EXCLUDED_PATH="${resolved}"
  fi
}

discover.selection() {
  local -a containers=() mounts=() options=()
  local line slot body source target choice remainder

  mapfile -t containers < <(pct list 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+$/ {print $1}')
  if [[ -z "${CTID}" && ${#containers[@]} -eq 1 ]]; then CTID="${containers[0]}"; fi
  if is.true "${INTERACTIVE}" && open.tty; then
    CTID="$(prompt.tty 'Enter target LXC CTID' "${CTID:-${containers[0]:-}}")"
  fi
  [[ "${CTID}" =~ ^[0-9]+$ ]] && pct config "${CTID}" >/dev/null 2>&1 \
    || die "Invalid or missing CTID: ${CTID:-empty}."

  while IFS= read -r line; do
    slot="${line%%:*}"
    body="${line#*: }"
    source="${body%%,*}"
    target="$(printf '%s\n' "${body}" | tr ',' '\n' | sed -n 's/^mp=//p' | head -n1)"
    [[ "${source}" == /* && "${source}" != / && -d "${source}" && "${target}" == /* ]] || continue
    mounts+=("${slot}|${source}|${target%/}")
  done < <(pct config "${CTID}" | grep -E '^mp[0-9]+:' || true)
  ((${#mounts[@]} > 0)) || die "No eligible bind mount was discovered for CT ${CTID}."

  if ((RECONCILE == 1)); then
    select.reconciliation.path "${mounts[@]}"
    return
  fi

  if [[ -z "${MOUNT_SLOT}" && ${#mounts[@]} -eq 1 ]]; then MOUNT_SLOT="${mounts[0]%%|*}"; fi
  if is.true "${INTERACTIVE}" && ((OPEN_TTY == 1)); then
    for line in "${mounts[@]}"; do options+=("${line//|/ | }"); done
    options+=("abort")
    choice="$(menu.tty 'Select the ZFS-backed bind mount to authorize:' "${options[@]}")"
    ((choice <= ${#mounts[@]})) || die 'Operator aborted.'
    MOUNT_SLOT="${mounts[$((choice - 1))]%%|*}"
  fi

  for line in "${mounts[@]}"; do
    [[ "${line%%|*}" == "${MOUNT_SLOT}" ]] || continue
    remainder="${line#*|}"
    SELECTED_SOURCE="${remainder%%|*}"
    SELECTED_TARGET="${line##*|}"
    SELECTED_PATH="${SELECTED_SOURCE}"
    SELECTED_CONTAINER_PATH="${SELECTED_TARGET}"
    return
  done
  die "Mount slot ${MOUNT_SLOT:-empty} was not discovered for CT ${CTID}."
}

resolve.reconciliation.identities() {
  local service_entry group_entry transfer_entry service_name group_name transfer_name password
  [[ "$(pct status "${CTID}" 2>/dev/null | awk '{print $2}')" == running ]] \
    || die "CT ${CTID} must be running for destination reconciliation."

  service_entry="$(pct exec "${CTID}" -- getent passwd "${SERVICE_USER}")" \
    || die "Service user ${SERVICE_USER} was not found in CT ${CTID}."
  IFS=: read -r service_name password SERVICE_UID SERVICE_GID _ _ _ <<< "${service_entry}"
  [[ "${service_name}" == "${SERVICE_USER}" && "${SERVICE_UID}" =~ ^[0-9]+$ && "${SERVICE_GID}" =~ ^[0-9]+$ ]] \
    || die 'The service-user identity record is invalid.'

  group_entry="$(pct exec "${CTID}" -- getent group "${SERVICE_GROUP}")" \
    || die "Service group ${SERVICE_GROUP} was not found in CT ${CTID}."
  IFS=: read -r group_name password SERVICE_GID _ <<< "${group_entry}"
  [[ "${group_name}" == "${SERVICE_GROUP}" && "${SERVICE_GID}" =~ ^[0-9]+$ ]] \
    || die 'The service-group identity record is invalid.'

  transfer_entry="$(pct exec "${CTID}" -- getent passwd "${TRANSFER_USER}")" \
    || die "Transfer user ${TRANSFER_USER} was not found in CT ${CTID}."
  IFS=: read -r transfer_name password TRANSFER_UID TRANSFER_GID _ _ _ <<< "${transfer_entry}"
  [[ "${transfer_name}" == "${TRANSFER_USER}" && "${TRANSFER_UID}" =~ ^[0-9]+$ \
    && "${TRANSFER_GID}" =~ ^[0-9]+$ ]] \
    || die 'The transfer-user identity record is invalid.'
  pct exec "${CTID}" -- /bin/sh -c 'command -v pgrep >/dev/null && command -v setpriv >/dev/null' \
    || die 'The container requires pgrep and setpriv for safe reconciliation.'
}

refuse.active.transfer() {
  local status
  if pct exec "${CTID}" -- pgrep -x rsync >/dev/null 2>&1; then
    die "CT ${CTID} has an active rsync process; finish or stop it before changing destination access."
  else
    status=$?
  fi
  [[ "${status}" -eq 1 ]] || die 'Unable to determine whether rsync is active in the container.'
}

map.container.id() {
  local kind="$1" container_id="$2" conf="${LXC_CONFIG_DIR}/${CTID}.conf"
  local container_start host_start length subordinate_path subordinate_count
  while read -r _ idmap_kind container_start host_start length; do
    [[ "${idmap_kind}" == "${kind}" ]] || continue
    if ((container_id >= container_start && container_id < container_start + length)); then
      printf '%s\n' "$((host_start + container_id - container_start))"
      return
    fi
  done < <(grep -E '^lxc\.idmap:[[:space:]]+[ug][[:space:]]+[0-9]+' "${conf}" 2>/dev/null || true)

  if [[ "$(pct config "${CTID}" | awk -F': ' '/^unprivileged:/ {print $2; exit}')" == 1 ]]; then
    if [[ "${kind}" == u ]]; then subordinate_path="${SUBUID_PATH}"; else subordinate_path="${SUBGID_PATH}"; fi
    IFS=: read -r host_start subordinate_count \
      <<< "$(awk -F: '$1=="root" {print $2 ":" $3; exit}' "${subordinate_path}")"
    [[ "${host_start}" =~ ^[0-9]+$ && "${subordinate_count}" =~ ^[0-9]+$ ]] \
      || die "Unable to resolve subordinate ${kind}id mapping."
    ((container_id < subordinate_count)) || die "Container ${kind}id ${container_id} is outside the subordinate mapping."
    printf '%s\n' "$((host_start + container_id))"
  else
    printf '%s\n' "${container_id}"
  fi
}

write.selection() {
  local owner_before="$1" host_uid="$2" host_gid="$3" transfer_host_uid="${4:-}" transfer_host_gid="${5:-}"
  local root_host_uid="${6:-}" root_host_gid="${7:-}"
  mkdir -p "${FACTS_DIR}"
  umask 077
  {
    printf '%s\n' '---' 'proxmox_lxc_storage_selection:' '  confirmed: true'
    printf '  profile: "%s"\n  ctid: %s\n  mount_slot: "%s"\n' "${STORAGE_PROFILE}" "${CTID}" "${MOUNT_SLOT}"
    printf '  mount_host_path: "%s"\n  host_path: "%s"\n  container_path: "%s"\n' \
      "${SELECTED_SOURCE}" "${SELECTED_PATH}" "${SELECTED_CONTAINER_PATH}"
    printf '  container_uid: %s\n  container_gid: %s\n  host_uid: %s\n  host_gid: %s\n  owner_before: "%s"\n' \
      "${SERVICE_UID}" "${SERVICE_GID}" "${host_uid}" "${host_gid}" "${owner_before}"
    if ((RECONCILE == 1)); then
      printf '  service_user: "%s"\n  service_group: "%s"\n  transfer_user: "%s"\n' \
        "${SERVICE_USER}" "${SERVICE_GROUP}" "${TRANSFER_USER}"
      printf '  transfer_container_uid: %s\n  transfer_container_gid: %s\n' "${TRANSFER_UID}" "${TRANSFER_GID}"
      printf '  transfer_host_uid: %s\n  transfer_host_gid: %s\n' "${transfer_host_uid}" "${transfer_host_gid}"
      printf '  root_container_uid: %s\n  root_container_gid: %s\n' "${ROOT_UID}" "${ROOT_GID}"
      printf '  root_host_uid: %s\n  root_host_gid: %s\n' "${root_host_uid}" "${root_host_gid}"
      if [[ -n "${EXCLUDE_CONTAINER_PATH}" ]]; then
        printf '  excluded_container_path: "%s"\n  excluded_host_path: "%s"\n' \
          "${EXCLUDE_CONTAINER_PATH}" "${EXCLUDED_PATH}"
      fi
    fi
  } > "${SELECTION_PATH}"
}

count.inaccessible() {
  local container_uid="$1" container_gid="$2" label="$3" count
  count="$(pct exec "${CTID}" -- env -u BASH_ENV -u ENV \
    setpriv "--reuid=${container_uid}" "--regid=${container_gid}" --clear-groups \
    /bin/bash --noprofile --norc -c '
      cd /
      set -o pipefail
      if [[ -n "$2" ]]; then
        find -P "$1" -xdev \( -path "$2" -prune \) -o \
          \( \( -type d \( ! -readable -o ! -writable -o ! -executable \) -printf x -prune \) \
          -o \( -type f \( ! -readable -o ! -writable \) -printf x \) \) | wc -c
      else
        find -P "$1" -xdev \
          \( \( -type d \( ! -readable -o ! -writable -o ! -executable \) -printf x -prune \) \
          -o \( -type f \( ! -readable -o ! -writable \) -printf x \) \) | wc -c
      fi
    ' mapped-storage-access "${SELECTED_CONTAINER_PATH}" "${EXCLUDE_CONTAINER_PATH}")" \
    || die "Unable to inspect effective ${label} access."
  count="${count//[[:space:]]/}"
  [[ "${count}" =~ ^[0-9]+$ ]] || die 'The inaccessible-entry count was not numeric.'
  printf '%s\n' "${count}"
}

find.selected() {
  local type="$1"
  if [[ -n "${EXCLUDED_PATH}" ]]; then
    find -P "${SELECTED_PATH}" -xdev \( -path "${EXCLUDED_PATH}" -prune \) -o -type "${type}" -print0
  else
    find -P "${SELECTED_PATH}" -xdev -type "${type}" -print0
  fi
}

find.selected.identity.owned() {
  local type="$1" service_host_uid="$2" transfer_host_uid="$3" root_host_uid="$4"
  local executable_filter="${5:-any}"
  local -a permission_expression=()
  case "${executable_filter}" in
    any) ;;
    executable) permission_expression=(-perm /0100) ;;
    non-executable) permission_expression=('!' -perm /0100) ;;
    *) die "Unsupported owner-access executable filter: ${executable_filter}" ;;
  esac
  if [[ -n "${EXCLUDED_PATH}" ]]; then
    find -P "${SELECTED_PATH}" -xdev \( -path "${EXCLUDED_PATH}" -prune \) -o \
      -type "${type}" \
      \( -uid "${service_host_uid}" -o -uid "${transfer_host_uid}" -o -uid "${root_host_uid}" \) \
      "${permission_expression[@]}" -print0
  else
    find -P "${SELECTED_PATH}" -xdev -type "${type}" \
      \( -uid "${service_host_uid}" -o -uid "${transfer_host_uid}" -o -uid "${root_host_uid}" \) \
      "${permission_expression[@]}" -print0
  fi
}

count.missing.default.acls() {
  local service_host_uid="$1" service_host_gid="$2" transfer_host_uid="$3" transfer_host_gid="$4"
  local root_host_uid="$5" root_host_gid="$6" count
  if ! count="$(
    find.selected d \
      | xargs -0 -r -n 256 getfacl -ncp -- \
      | awk \
        -v service_user="default:user:${service_host_uid}:rwx" \
        -v service_group="default:group:${service_host_gid}:rwx" \
        -v transfer_user="default:user:${transfer_host_uid}:rwx" \
        -v transfer_group="default:group:${transfer_host_gid}:rwx" \
        -v root_user="default:user:${root_host_uid}:rwx" \
        -v root_group="default:group:${root_host_gid}:rwx" \
        -v owner_default="default:user::rwx" '
          BEGIN { RS = ""; missing = 0 }
          {
            found_service_user = found_service_group = 0
            found_transfer_user = found_transfer_group = 0
            found_root_user = found_root_group = 0
            found_owner_default = 0
            line_count = split($0, lines, "\n")
            for (line = 1; line <= line_count; line++) {
              if (lines[line] == service_user) found_service_user = 1
              if (lines[line] == service_group) found_service_group = 1
              if (lines[line] == transfer_user) found_transfer_user = 1
              if (lines[line] == transfer_group) found_transfer_group = 1
              if (lines[line] == root_user) found_root_user = 1
              if (lines[line] == root_group) found_root_group = 1
              if (lines[line] == owner_default) found_owner_default = 1
            }
            if (!(found_service_user && found_service_group &&
                  found_transfer_user && found_transfer_group &&
                  found_root_user && found_root_group &&
                  found_owner_default)) missing++
          }
          END { print missing + 0 }
        '
  )"; then
    die 'Unable to verify inherited destination ACLs.'
  fi
  count="${count//[[:space:]]/}"
  [[ "${count}" =~ ^[0-9]+$ ]] || die 'The missing-default-ACL count was not numeric.'
  printf '%s\n' "${count}"
}

apply.identity.owner.access() {
  local service_host_uid="$1" transfer_host_uid="$2" root_host_uid="$3"
  # POSIX ACL lookup stops at user:: for a matching owner UID. A named entry
  # for that UID cannot repair restrictive owner permissions, so lift only
  # the three presentation identities and retain regular-file execute state.
  find.selected.identity.owned d "${service_host_uid}" "${transfer_host_uid}" "${root_host_uid}" any \
    | xargs -0 -r -n 256 setfacl -m 'u::rwx'
  find.selected.identity.owned f "${service_host_uid}" "${transfer_host_uid}" "${root_host_uid}" executable \
    | xargs -0 -r -n 256 setfacl -m 'u::rwx'
  find.selected.identity.owned f "${service_host_uid}" "${transfer_host_uid}" "${root_host_uid}" non-executable \
    | xargs -0 -r -n 256 setfacl -m 'u::rw-'
}

verify.reconciliation() {
  local service_host_uid="$1" service_host_gid="$2" transfer_host_uid="$3" transfer_host_gid="$4"
  local root_host_uid="$5" root_host_gid="$6" service_inaccessible transfer_inaccessible root_inaccessible missing_defaults
  refuse.active.transfer
  service_inaccessible="$(count.inaccessible "${SERVICE_UID}" "${SERVICE_GID}" "service identity ${SERVICE_USER}")"
  transfer_inaccessible="$(count.inaccessible "${TRANSFER_UID}" "${TRANSFER_GID}" "transfer identity ${TRANSFER_USER}")"
  root_inaccessible="$(count.inaccessible "${ROOT_UID}" "${ROOT_GID}" 'container root identity')"
  missing_defaults="$(count.missing.default.acls \
    "${service_host_uid}" "${service_host_gid}" "${transfer_host_uid}" "${transfer_host_gid}" \
    "${root_host_uid}" "${root_host_gid}")"
  printf '  inaccessible service entries: %s\n  inaccessible transfer entries: %s\n  inaccessible root entries: %s\n  directories missing inherited ACLs: %s\n' \
    "${service_inaccessible}" "${transfer_inaccessible}" "${root_inaccessible}" "${missing_defaults}" >&2
  [[ "${service_inaccessible}" -eq 0 ]] \
    || die "${service_inaccessible} entries remain inaccessible to ${SERVICE_USER}."
  [[ "${transfer_inaccessible}" -eq 0 ]] \
    || die "${transfer_inaccessible} entries remain inaccessible to ${TRANSFER_USER}."
  [[ "${root_inaccessible}" -eq 0 ]] \
    || die "${root_inaccessible} entries remain inaccessible to container root."
  [[ "${missing_defaults}" -eq 0 ]] || die "${missing_defaults} directories lack the required default ACLs."
  log "Destination ACL verification passed for ${SELECTED_CONTAINER_PATH}."
}

apply.reconciliation() {
  local service_host_uid="$1" service_host_gid="$2" transfer_host_uid="$3" transfer_host_gid="$4"
  local root_host_uid="$5" root_host_gid="$6"
  refuse.active.transfer
  log 'Applying restartable ACL batches without changing ownership or removing executable bits.'
  find.selected d \
    | xargs -0 -r -n 256 setfacl -m \
      "u:${service_host_uid}:rwx,g:${service_host_gid}:rwx,d:u:${service_host_uid}:rwx,d:g:${service_host_gid}:rwx" \
      -m "u:${transfer_host_uid}:rwx,g:${transfer_host_gid}:rwx,d:u:${transfer_host_uid}:rwx,d:g:${transfer_host_gid}:rwx" \
      -m "u:${root_host_uid}:rwx,g:${root_host_gid}:rwx,d:u:${root_host_uid}:rwx,d:g:${root_host_gid}:rwx" \
      -m 'm::rwx,d:u::rwx,d:m::rwx'
  find.selected f \
    | xargs -0 -r -n 256 setfacl -m \
      "u:${service_host_uid}:rw-,g:${service_host_gid}:rw-" \
      -m "u:${transfer_host_uid}:rw-,g:${transfer_host_gid}:rw-" \
      -m "u:${root_host_uid}:rw-,g:${root_host_gid}:rw-" \
      -m 'm::rwx'
  apply.identity.owner.access "${service_host_uid}" "${transfer_host_uid}" "${root_host_uid}"
}

verify.transfer.destination() {
  local service_host_uid="$1" service_host_gid="$2" transfer_host_uid="$3" transfer_host_gid="$4"
  local root_host_uid="$5" root_host_gid="$6"
  local owner acl entry
  refuse.active.transfer
  owner="$(stat -c '%u:%g' "${SELECTED_PATH}")"
  [[ "${owner}" == "${transfer_host_uid}:${transfer_host_gid}" ]] \
    || die "The destination root is not owned by mapped ${TRANSFER_USER}: ${owner}."
  acl="$(getfacl -ncp -- "${SELECTED_PATH}")"
  for entry in \
    "user:${service_host_uid}:rwx" "group:${service_host_gid}:rwx" \
    "user:${transfer_host_uid}:rwx" "group:${transfer_host_gid}:rwx" \
    "user:${root_host_uid}:rwx" "group:${root_host_gid}:rwx" \
    "mask::rwx" \
    "default:user:${service_host_uid}:rwx" "default:group:${service_host_gid}:rwx" \
    "default:user:${transfer_host_uid}:rwx" "default:group:${transfer_host_gid}:rwx" \
    "default:user:${root_host_uid}:rwx" "default:group:${root_host_gid}:rwx" \
    "default:mask::rwx"; do
    grep -Fxq "${entry}" <<< "${acl}" || die "The destination root is missing ACL entry: ${entry}."
  done
  pct exec "${CTID}" -- env -u BASH_ENV -u ENV \
    setpriv "--reuid=${TRANSFER_UID}" "--regid=${TRANSFER_GID}" --clear-groups \
    /bin/sh -c 'cd / && test -O "$1" && test -r "$1" && test -w "$1" && test -x "$1"' \
    mapped-transfer-access "${SELECTED_CONTAINER_PATH}" \
    || die "Transfer identity ${TRANSFER_USER} does not own and have read/write/traverse access to the destination root."
  pct exec "${CTID}" -- env -u BASH_ENV -u ENV \
    setpriv "--reuid=${SERVICE_UID}" "--regid=${SERVICE_GID}" --clear-groups \
    /bin/sh -c 'cd / && test -r "$1" && test -w "$1" && test -x "$1"' \
    mapped-service-access "${SELECTED_CONTAINER_PATH}" \
    || die "Service identity ${SERVICE_USER} cannot read/write/traverse the destination root."
  pct exec "${CTID}" -- env -u BASH_ENV -u ENV \
    setpriv "--reuid=${ROOT_UID}" "--regid=${ROOT_GID}" --clear-groups \
    /bin/sh -c 'cd / && test -r "$1" && test -w "$1" && test -x "$1"' \
    mapped-root-access "${SELECTED_CONTAINER_PATH}" \
    || die 'Container root cannot read/write/traverse the destination root.'
  log "Transfer destination verification passed for ${SELECTED_CONTAINER_PATH}."
}

apply.transfer.destination() {
  local service_host_uid="$1" service_host_gid="$2" transfer_host_uid="$3" transfer_host_gid="$4"
  local root_host_uid="$5" root_host_gid="$6"
  refuse.active.transfer
  log 'Preparing only the selected destination root; descendants are not changed.'
  chown --no-dereference "${transfer_host_uid}:${transfer_host_gid}" "${SELECTED_PATH}"
  setfacl -m \
    "u:${service_host_uid}:rwx,g:${service_host_gid}:rwx" \
    -m "u:${transfer_host_uid}:rwx,g:${transfer_host_gid}:rwx" \
    -m "u:${root_host_uid}:rwx,g:${root_host_gid}:rwx" \
    -m 'm::rwx' \
    -m "d:u:${service_host_uid}:rwx,d:g:${service_host_gid}:rwx" \
    -m "d:u:${transfer_host_uid}:rwx,d:g:${transfer_host_gid}:rwx" \
    -m "d:u:${root_host_uid}:rwx,d:g:${root_host_gid}:rwx" \
    -m 'd:m::rwx' \
    -- "${SELECTED_PATH}"
}

apply.legacy() {
  local host_uid="$1" host_gid="$2"
  setfacl -m "u:${host_uid}:rwx,g:${host_gid}:rwx,d:u:${host_uid}:rwx,d:g:${host_gid}:rwx" "${SELECTED_PATH}"
  if [[ "${MODE}" == apply-recursive ]]; then
    log 'Applying restartable ACL batches to existing directories and files; this may take a long time on large datasets.'
    find -P "${SELECTED_PATH}" -xdev -type d -print0 \
      | xargs -0 -r -n 256 setfacl -m "u:${host_uid}:rwx,g:${host_gid}:rwx"
    find -P "${SELECTED_PATH}" -xdev -type f -print0 \
      | xargs -0 -r -n 256 setfacl -m "u:${host_uid}:rw-,g:${host_gid}:rw-"
  fi
}

verify.legacy() {
  local host_uid="$1" host_gid="$2"
  getfacl -ncp "${SELECTED_PATH}" | grep -Eq "^user:${host_uid}:rwx$" \
    || die 'Mapped user ACL verification failed.'
  getfacl -ncp "${SELECTED_PATH}" | grep -Eq "^group:${host_gid}:rwx$" \
    || die 'Mapped group ACL verification failed.'
  [[ "$(pct status "${CTID}" 2>/dev/null | awk '{print $2}')" == running ]] \
    || die "CT ${CTID} must be running for mapped identity verification."
  pct exec "${CTID}" -- env -u BASH_ENV -u ENV \
    setpriv "--reuid=${SERVICE_UID}" "--regid=${SERVICE_GID}" --clear-groups \
    /bin/sh -c 'cd / && test -r "$1" && test -w "$1" && test -x "$1"' mapped-storage-access "${SELECTED_CONTAINER_PATH}" \
    || die 'Mapped service identity cannot read/write/traverse the container mount.'
}

main() {
  local host_uid host_gid transfer_host_uid="" transfer_host_gid="" root_host_uid="" root_host_gid=""
  local owner_before owner_after confirm service_inaccessible_before transfer_inaccessible_before root_inaccessible_before
  require.host
  discover.selection
  if ((RECONCILE == 1)); then
    resolve.reconciliation.identities
    refuse.active.transfer
  fi
  host_uid="$(map.container.id u "${SERVICE_UID}")"
  host_gid="$(map.container.id g "${SERVICE_GID}")"
  if ((RECONCILE == 1)); then
    transfer_host_uid="$(map.container.id u "${TRANSFER_UID}")"
    transfer_host_gid="$(map.container.id g "${TRANSFER_GID}")"
    root_host_uid="$(map.container.id u "${ROOT_UID}")"
    root_host_gid="$(map.container.id g "${ROOT_GID}")"
  fi
  owner_before="$(stat -c '%u:%g' "${SELECTED_PATH}")"
  write.selection "${owner_before}" "${host_uid}" "${host_gid}" "${transfer_host_uid}" "${transfer_host_gid}" \
    "${root_host_uid}" "${root_host_gid}"

  printf '\nStorage ACL plan:\n  profile: %s\n  mode: %s\n  CT: %s\n  bind source: %s\n  host target: %s\n  container target: %s\n  service mapped uid:gid: %s:%s\n  owner before: %s\n' \
    "${STORAGE_PROFILE}" "${MODE}" "${CTID}" "${SELECTED_SOURCE}" "${SELECTED_PATH}" "${SELECTED_CONTAINER_PATH}" \
    "${host_uid}" "${host_gid}" "${owner_before}" >&2
  if ((RECONCILE == 1)); then
    printf '  service identity: %s:%s (%s:%s)\n  transfer identity: %s (%s:%s)\n  container root mapped uid:gid: %s:%s\n' \
      "${SERVICE_USER}" "${SERVICE_GROUP}" "${host_uid}" "${host_gid}" \
      "${TRANSFER_USER}" "${transfer_host_uid}" "${transfer_host_gid}" "${root_host_uid}" "${root_host_gid}" >&2
    if [[ -n "${EXCLUDE_CONTAINER_PATH}" ]]; then
      printf '  excluded container subtree: %s\n  excluded host subtree: %s\n' \
        "${EXCLUDE_CONTAINER_PATH}" "${EXCLUDED_PATH}" >&2
    fi
    if ((PREPARE_TRANSFER == 0)); then
      service_inaccessible_before="$(count.inaccessible "${SERVICE_UID}" "${SERVICE_GID}" "service identity ${SERVICE_USER}")"
      transfer_inaccessible_before="$(count.inaccessible "${TRANSFER_UID}" "${TRANSFER_GID}" "transfer identity ${TRANSFER_USER}")"
      root_inaccessible_before="$(count.inaccessible "${ROOT_UID}" "${ROOT_GID}" 'container root identity')"
      printf '  inaccessible service entries before apply: %s\n  inaccessible transfer entries before apply: %s\n  inaccessible root entries before apply: %s\n' \
        "${service_inaccessible_before}" "${transfer_inaccessible_before}" "${root_inaccessible_before}" >&2
    fi
  fi

  if [[ "${MODE}" == preflight ]]; then
    log "Preflight complete; no ACL changed. Selection: ${SELECTION_PATH}"
    return
  fi
  if [[ "${MODE}" == verify ]]; then
    if ((PREPARE_TRANSFER == 1)); then
      verify.transfer.destination "${host_uid}" "${host_gid}" "${transfer_host_uid}" "${transfer_host_gid}" \
        "${root_host_uid}" "${root_host_gid}"
    else
      verify.reconciliation "${host_uid}" "${host_gid}" "${transfer_host_uid}" "${transfer_host_gid}" \
        "${root_host_uid}" "${root_host_gid}"
    fi
    return
  fi

  if is.true "${INTERACTIVE}" && ((OPEN_TTY == 1)); then
    if ((PREPARE_TRANSFER == 1)); then
      confirm="$(prompt.tty "Type yes to prepare the destination root for ${TRANSFER_USER} without changing descendants" no)"
    else
      confirm="$(prompt.tty "Type yes to apply mapped ACLs (${MODE}) without changing ownership" no)"
    fi
    [[ "${confirm}" == yes ]] || die 'Operator aborted before mutation.'
  fi

  if ((PREPARE_TRANSFER == 1)); then
    [[ "${MODE}" == apply ]] || die 'Transfer destination preparation uses apply, not apply-recursive.'
    apply.transfer.destination "${host_uid}" "${host_gid}" "${transfer_host_uid}" "${transfer_host_gid}" \
      "${root_host_uid}" "${root_host_gid}"
  elif ((RECONCILE == 1)); then
    [[ "${MODE}" == apply ]] || die 'Destination reconciliation uses apply, not apply-recursive.'
    apply.reconciliation "${host_uid}" "${host_gid}" "${transfer_host_uid}" "${transfer_host_gid}" \
      "${root_host_uid}" "${root_host_gid}"
  else
    apply.legacy "${host_uid}" "${host_gid}"
  fi
  owner_after="$(stat -c '%u:%g' "${SELECTED_PATH}")"
  if ((PREPARE_TRANSFER == 1)); then
    [[ "${owner_after}" == "${transfer_host_uid}:${transfer_host_gid}" ]] \
      || die "Destination-root ownership preparation failed (${owner_after})."
  else
    [[ "${owner_after}" == "${owner_before}" ]] \
      || die "Ownership changed unexpectedly (${owner_before} -> ${owner_after})."
  fi

  if ((PREPARE_TRANSFER == 1)); then
    verify.transfer.destination "${host_uid}" "${host_gid}" "${transfer_host_uid}" "${transfer_host_gid}" \
      "${root_host_uid}" "${root_host_gid}"
  elif ((RECONCILE == 1)); then
    verify.reconciliation "${host_uid}" "${host_gid}" "${transfer_host_uid}" "${transfer_host_gid}" \
      "${root_host_uid}" "${root_host_gid}"
  else
    verify.legacy "${host_uid}" "${host_gid}"
  fi
  log "Mapped ACL operation completed in ${MODE} mode; ownership is ${owner_after}."
}

if ! is.true "${PROXMOX_LXC_STORAGE_SOURCE_ONLY:-0}"; then
  main "$@"
fi
