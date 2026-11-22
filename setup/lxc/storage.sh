#!/usr/bin/env bash
## Map a fixed non-root Samba service identity onto a Proxmox bind mount.
## Run on the Proxmox host after the LXC and mountpoint exist.

set -euo pipefail

log()       { printf '[setup.lxc.storage] %s\n' "$*" >&2; }
log.error() { printf '[setup.lxc.storage][error] %s\n' "$*" >&2; }

MODE="${1:-${PROXMOX_LXC_STORAGE_MODE:-preflight}}"
CTID="${PROXMOX_CTID:-}"
MOUNT_SLOT="${PROXMOX_LXC_STORAGE_MOUNT_SLOT:-}"
SERVICE_UID="${PROXMOX_LXC_STORAGE_SERVICE_UID:-2000}"
SERVICE_GID="${PROXMOX_LXC_STORAGE_SERVICE_GID:-2000}"
FACTS_DIR="${PROXMOX_LXC_STORAGE_FACTS_DIR:-/etc/ansible/proxmox/facts}"
SELECTION_PATH="${PROXMOX_LXC_STORAGE_SELECTION_PATH:-${FACTS_DIR}/lxc.storage.selection.yml}"
INTERACTIVE="${PROXMOX_LXC_STORAGE_INTERACTIVE:-1}"
OPEN_TTY=0

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
  [[ "$(id -u)" -eq 0 ]] || { log.error 'Run as root on the Proxmox host.'; exit 1; }
  command -v pveversion >/dev/null 2>&1 || { log.error 'pveversion was not found.'; exit 1; }
  command -v pct >/dev/null 2>&1 || { log.error 'pct was not found.'; exit 1; }
  command -v setfacl >/dev/null 2>&1 || { log.error 'setfacl was not found; install the acl package.'; exit 1; }
  case "${MODE}" in preflight|apply|apply-recursive) ;; *) log.error 'Mode must be preflight, apply, or apply-recursive.'; exit 1 ;; esac
  [[ "${SERVICE_UID}" =~ ^[0-9]+$ && "${SERVICE_GID}" =~ ^[0-9]+$ ]] || { log.error 'Service UID/GID must be numeric.'; exit 1; }
}

discover.selection() {
  local -a containers=() mounts=() options=()
  local id line slot body source target choice

  mapfile -t containers < <(pct list 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+$/ {print $1}')
  if [[ -z "${CTID}" && ${#containers[@]} -eq 1 ]]; then CTID="${containers[0]}"; fi
  if is.true "${INTERACTIVE}" && open.tty; then
    CTID="$(prompt.tty 'Enter target LXC CTID' "${CTID:-${containers[0]:-}}")"
  fi
  [[ "${CTID}" =~ ^[0-9]+$ ]] && pct config "${CTID}" >/dev/null 2>&1 || { log.error "Invalid or missing CTID: ${CTID:-empty}"; exit 1; }

  while IFS= read -r line; do
    slot="${line%%:*}"
    body="${line#*: }"
    source="${body%%,*}"
    target="$(printf '%s\n' "${body}" | tr ',' '\n' | sed -n 's/^mp=//p' | head -n1)"
    [[ "${source}" == /* && "${source}" != "/" && -d "${source}" ]] || continue
    mounts+=("${slot}|${source}|${target}")
  done < <(pct config "${CTID}" | grep -E '^mp[0-9]+:' || true)
  ((${#mounts[@]} > 0)) || { log.error "No eligible bind mount was discovered for CT ${CTID}."; exit 1; }

  if [[ -z "${MOUNT_SLOT}" && ${#mounts[@]} -eq 1 ]]; then MOUNT_SLOT="${mounts[0]%%|*}"; fi
  if is.true "${INTERACTIVE}" && ((OPEN_TTY == 1)); then
    for line in "${mounts[@]}"; do options+=("${line//|/ | }"); done
    options+=("abort")
    choice="$(menu.tty 'Select the ZFS-backed bind mount to authorize:' "${options[@]}")"
    ((choice <= ${#mounts[@]})) || { log.error 'Operator aborted.'; exit 1; }
    MOUNT_SLOT="${mounts[$((choice - 1))]%%|*}"
  fi

  for line in "${mounts[@]}"; do
    [[ "${line%%|*}" == "${MOUNT_SLOT}" ]] || continue
    SELECTED_SOURCE="${line#*|}"; SELECTED_SOURCE="${SELECTED_SOURCE%%|*}"
    SELECTED_TARGET="${line##*|}"
    return 0
  done
  log.error "Mount slot ${MOUNT_SLOT:-empty} was not discovered for CT ${CTID}."
  exit 1
}

map.container.id() {
  local kind="$1" container_id="$2" conf="/etc/pve/lxc/${CTID}.conf"
  local container_start host_start length
  while read -r _ idmap_kind container_start host_start length; do
    [[ "${idmap_kind}" == "${kind}" ]] || continue
    if ((container_id >= container_start && container_id < container_start + length)); then
      printf '%s\n' "$((host_start + container_id - container_start))"
      return 0
    fi
  done < <(grep -E '^lxc\.idmap:[[:space:]]+[ug][[:space:]]+[0-9]+' "${conf}" 2>/dev/null || true)

  if [[ "$(pct config "${CTID}" | awk -F': ' '/^unprivileged:/ {print $2; exit}')" == "1" ]]; then
    if [[ "${kind}" == "u" ]]; then host_start="$(awk -F: '$1=="root" {print $2; exit}' /etc/subuid)"; else host_start="$(awk -F: '$1=="root" {print $2; exit}' /etc/subgid)"; fi
    [[ "${host_start}" =~ ^[0-9]+$ ]] || { log.error "Unable to resolve subordinate ${kind}id mapping."; exit 1; }
    printf '%s\n' "$((host_start + container_id))"
  else
    printf '%s\n' "${container_id}"
  fi
}

write.selection() {
  local owner_before="$1" host_uid="$2" host_gid="$3"
  mkdir -p "${FACTS_DIR}"
  umask 077
  {
    printf '%s\n' '---' 'proxmox_lxc_storage_selection:' '  confirmed: true'
    printf '  ctid: %s\n  mount_slot: "%s"\n  host_path: "%s"\n  container_path: "%s"\n' "${CTID}" "${MOUNT_SLOT}" "${SELECTED_SOURCE}" "${SELECTED_TARGET}"
    printf '  container_uid: %s\n  container_gid: %s\n  host_uid: %s\n  host_gid: %s\n  owner_before: "%s"\n' "${SERVICE_UID}" "${SERVICE_GID}" "${host_uid}" "${host_gid}" "${owner_before}"
  } > "${SELECTION_PATH}"
}

main() {
  local host_uid host_gid owner_before owner_after confirm
  require.host
  discover.selection
  host_uid="$(map.container.id u "${SERVICE_UID}")"
  host_gid="$(map.container.id g "${SERVICE_GID}")"
  owner_before="$(stat -c '%u:%g' "${SELECTED_SOURCE}")"
  write.selection "${owner_before}" "${host_uid}" "${host_gid}"

  printf '\nStorage ACL plan:\n  CT: %s\n  host: %s\n  container: %s\n  mapped uid:gid: %s:%s\n  preserved owner: %s\n' \
    "${CTID}" "${SELECTED_SOURCE}" "${SELECTED_TARGET}" "${host_uid}" "${host_gid}" "${owner_before}" >&2
  [[ "${MODE}" == "apply" || "${MODE}" == "apply-recursive" ]] || { log "Preflight complete: ${SELECTION_PATH}"; return 0; }
  if is.true "${INTERACTIVE}" && ((OPEN_TTY == 1)); then
    confirm="$(prompt.tty "Type yes to apply mapped ACLs (${MODE}) without changing ownership" 'no')"
    [[ "${confirm}" == "yes" ]] || { log.error 'Operator aborted before mutation.'; exit 1; }
  fi

  setfacl -m "u:${host_uid}:rwx,g:${host_gid}:rwx,d:u:${host_uid}:rwx,d:g:${host_gid}:rwx" "${SELECTED_SOURCE}"
  if [[ "${MODE}" == "apply-recursive" ]]; then
    log 'Applying restartable ACL batches to existing directories and files; this may take a long time on large datasets.'
    find "${SELECTED_SOURCE}" -xdev -type d -print0 | xargs -0 -r -n 256 setfacl -m "u:${host_uid}:rwx,g:${host_gid}:rwx"
    find "${SELECTED_SOURCE}" -xdev -type f -print0 | xargs -0 -r -n 256 setfacl -m "u:${host_uid}:rw-,g:${host_gid}:rw-"
  fi
  owner_after="$(stat -c '%u:%g' "${SELECTED_SOURCE}")"
  [[ "${owner_after}" == "${owner_before}" ]] || { log.error "Ownership changed unexpectedly (${owner_before} -> ${owner_after})."; exit 1; }
  getfacl -ncp "${SELECTED_SOURCE}" | grep -Eq "^user:${host_uid}:rwx$" || { log.error 'Mapped user ACL verification failed.'; exit 1; }
  getfacl -ncp "${SELECTED_SOURCE}" | grep -Eq "^group:${host_gid}:rwx$" || { log.error 'Mapped group ACL verification failed.'; exit 1; }
  [[ "$(pct status "${CTID}" 2>/dev/null | awk '{print $2}')" == running ]] \
    || { log.error "CT ${CTID} must be running for mapped identity verification."; exit 1; }
  pct exec "${CTID}" -- setpriv "--reuid=${SERVICE_UID}" "--regid=${SERVICE_GID}" --clear-groups \
    /bin/bash -c 'test -r "$1" && test -w "$1" && test -x "$1"' mapped-storage-access "${SELECTED_TARGET}" \
    || { log.error 'Mapped service identity cannot read/write/traverse the container mount.'; exit 1; }
  log "Mapped ACL applied in ${MODE} mode; ownership remains ${owner_after}."
}

main "$@"
