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

# --- Resolve repo root (script lives in ./actions/) ---
PATH_TO[scripts]="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATH_TO[root]="$(cd "${PATH_TO[scripts]}/.." && pwd)"
cd "${PATH_TO[root]}"


# --- Publish directory (overrideable from env: DIR_PUBLISH / PUBLISH_DIR) ---
PATH_TO[publish]="${DIR_PUBLISH:-${PUBLISH_DIR:-static}}"

# --- Whitelist config (file-based; anchored at repo root) ---
WHITELIST[ansible]="${PATH_TO[root]}/ansible/whitelist.txt"

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
# Reads ansible/whitelist.txt and stores non-empty, non-comment
# entries in PKGS[ansible] as a space-separated list.

load.whitelist.ansible() {
  local file="${WHITELIST[ansible]}"

  if [[ ! -f "${file}" ]]; then
    log.error "${ERROR[whitelist]}"
    exit 1
  fi

  local items=()
  local line

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue                    # skip blanks
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue     # skip comments
    items+=("${line}")
  done < "${file}"

  # store as space-separated list on the PKGS "object"
  PKGS[ansible]="${items[*]}"
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

publish.ansible() {
  log.info "[www.pages] syncing ansible whitelist"
  mkdir -p "${PATH_TO[publish]}/ansible"

  load.whitelist.ansible

  local rsync_includes=()
  local playbook

  # PKGS[ansible] is a space-separated list of playbooks
  for playbook in ${PKGS[ansible]}; do
    rsync_includes+=( "--include=${playbook}" )
  done
  
  log.info "[www.pages] whitelist entries: ${PKGS[ansible]}"

  rsync -av \
    "${rsync_includes[@]}" \
    --exclude='*' \
    ansible/ "${PATH_TO[publish]}/ansible/"
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
  publish.ansible

  log.info "${MSG[done]}"
}

run.pages "$@"