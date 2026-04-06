#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# Objects / maps
# -------------------------

declare -A PATH_TO
declare -A MSG
declare -A ERROR
declare -A WHITELIST
declare -A PKGS

# --- Playlist (Of Playbooks) File Name:
PLAYBOOKS="debian/install.playbooks.txt"

# --- Resolve repo root (script lives in ./actions/) ---
PATH_TO[scripts]="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATH_TO[root]="$(cd "${PATH_TO[scripts]}/.." && pwd)"
cd "${PATH_TO[root]}"


# --- Publish directory (overrideable from env: DIR_PUBLISH / PUBLISH_DIR) ---
PATH_TO[publish]="${DIR_PUBLISH:-${PUBLISH_DIR:-static}}"

# --- Whitelist config (file-based; anchored at repo root) ---
WHITELIST[ansible]="${PATH_TO[root]}/ansible/${PLAYBOOKS}"

# --- Messages ---
MSG[start]="[www.pages] repo root: ${PATH_TO[root]}"
MSG[build]="[www.pages] building into: ${PATH_TO[publish]}"
MSG[done]="[www.pages] done"
MSG[warn_www]="[www.pages] WARNING: www/ directory not found; skipping landing HTML"

# --- Errors (style: ERROR[...]) ---
ERROR[bootstrap]="[www.pages] ERROR[bootstrap]: bootstrap/metal.sh not found"
ERROR[whitelist]="[www.pages] ERROR[whitelist]: ansible whitelist file not found: ${WHITELIST[ansible]}"

# -------------------------
# Logging helpers
# -------------------------

log.info() {
  echo "$1"
}

log.warn() {
  echo "$1" >&2
}

log.error() {
  echo "$1" >&2
}

# -------------------------
# Whitelist loader
# -------------------------
# Reads ansible/${PLAYBOOKS} and stores non-empty, non-comment
# entries in PKGS[ansible] as a space-separated list.


load.whitelist.ansible() {
  local file="${WHITELIST[ansible]}"
  [[ -f "${file}" ]] || { log.error "${ERROR[whitelist]}"; exit 1; }

  # Read non-comment, non-blank lines into a temp array
  mapfile -t _ansible_items < <(
    sed 's/[[:space:]]*$//' "${file}" | grep -vE '^[[:space:]]*(#|$)'
  )

  if ((${#_ansible_items[@]} == 0)); then
    log.error "[www.pages] ERROR[whitelist]: ansible whitelist is empty"
    exit 1
  fi

  PKGS[ansible]="${_ansible_items[*]}"  # space-separated string, of playbook files
}

# -------------------------
# Helpers
# -------------------------

publish.prepare() {
  rm -rf "${PATH_TO[publish]}"
  mkdir -p "${PATH_TO[publish]}"
}


publish.www() {
  if [[ -d "www" ]]; then
    log.info "[www.pages] copying ./www -> ${PATH_TO[publish]}"
    rsync -av www/ "${PATH_TO[publish]}/"
  else
    log.warn "${MSG[warn_www]}"
  fi
}

publish.bootstrap() {
  if [[ -f "bootstrap/metal.sh" ]]; then
    log.info "[www.pages] installing metal.sh"
    install -m 0755 "bootstrap/metal.sh" "${PATH_TO[publish]}/metal.sh"
  else
    log.error "${ERROR[bootstrap]}"
    exit 1
  fi
}

publish.proxmox64() {
  if [[ -f "bootstrap/release.6.4.sh" ]]; then
    log.info "[www.pages] installing 6.4.sh"
    install -m 0755 "bootstrap/release.6.4.sh" "${PATH_TO[publish]}/6.4.sh"
  else
    log.warn "[www.pages] release.6.4.sh not found; skipping 6.4.sh publish"
  fi
}

publish.ansible() {
  log.info "[www.pages] syncing ansible whitelist"
  mkdir -p "${PATH_TO[publish]}/ansible"

  load.whitelist.ansible   # populates PKGS[ansible]

  local rsync_includes=(
    "--include=${PLAYBOOKS}"          # playlist file
    "--include=config.github.yml"     # shared config consumed by bootstrap
    "--include=group_vars/"           # shared vars directory
    "--include=group_vars/all.yml"    # global vars for playbooks
    "--include=debian.packages.yml"   # package catalog used by playbooks
  )
  local playbook_to_run
  for playbook_to_run in ${PKGS[ansible]}; do
    rsync_includes+=( "--include=debian/${playbook_to_run}" )
  done

  log.info "[www.pages] whitelist entries: ${PKGS[ansible]}"

  rsync -av \
    --include='*/' \
    "${rsync_includes[@]}" \
    --exclude='*' \
    ansible/ "${PATH_TO[publish]}/ansible/"
}

publish.ansible.release64() {
  if [[ -d "ansible/release/6.4" ]]; then
    log.info "[www.pages] syncing ansible release/6.4"
    rsync -av ansible/release/6.4/ "${PATH_TO[publish]}/ansible/release/6.4/"
  else
    log.warn "[www.pages] ansible/release/6.4 not found; skipping"
  fi
}


# -------------------------
# Main runner
# -------------------------

run.pages() {
  log.info "${MSG[start]}"
  log.info "${MSG[build]}"

  publish.prepare
  publish.www
  publish.bootstrap
  publish.proxmox64
  publish.ansible
  publish.ansible.release64

  log.info "${MSG[done]}"
}

run.pages "$@"
