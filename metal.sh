#!/usr/bin/env bash
## Bootstrap: bare-metal Debian (devs.guide/proxmox)
## Responsibility:
##   - system.ensure.root
##   - system.ensure.apt
##   - install.ansible
##   - fetch.playbook
##   - run.playbook
##
## Everything else lives in: repo-root/ansible

set -euo pipefail

declare -A GITHUB
declare -A PLAYBOOK
declare -A PLAYLIST
declare -A GROUPVARS
declare -A MSG

# --- GitHub metadata ---
GITHUB[user]='devs-guide'
GITHUB[repo]='proxmox'
GITHUB[url]="https://${GITHUB[user]}.github.io/${GITHUB[repo]}"

# --- Playbook metadata (set per playlist entry) ---
PLAYBOOK[name]=''
PLAYBOOK[url]=''
PLAYBOOK[path]=''

# --- Playlist (whitelist) metadata ---
PLAYLIST[name]='debian/install.playbooks.txt'
PLAYLIST[url]="${GITHUB[url]}/ansible/${PLAYLIST[name]}"
PLAYLIST[path]="/tmp/debian.install.playbooks.txt"

# --- Global group_vars (shared across playbooks) ---
GROUPVARS[dir]="/tmp/group_vars"
GROUPVARS[file]="all.yml"
GROUPVARS[url]="${GITHUB[url]}/ansible/group_vars/${GROUPVARS[file]}"
GROUPVARS[path]="${GROUPVARS[dir]}/${GROUPVARS[file]}"



# --- Messages ---
MSG[fail]=$(cat <<EOF
[metal]: Please log in as root, then run:

  wget -qO- ${GITHUB[url]}/metal.sh | bash

Example (if you have the root password):

  su -
  wget -qO- ${GITHUB[url]}/metal.sh | bash

EOF
)

MSG[success]="Bootstrap finished successfully."
MSG[fatal]="Fatal error encountered"

# --- Logging helpers ---
log.info()   { printf '[metal] %s\n' "$*" >&2; }
log.error()  { printf '[metal][error] %s\n' "$*" >&2; }
log.error.fatal() { printf '%s\n' "${MSG[fatal]}" >&2; }
log() { log.info "$@"; }

TMP_DIR="/tmp/proxmox-metal"
PAGES_BASE_URL="${GITHUB[url]}"
COMMON_HELPER_PATH="${TMP_DIR}/release.common.sh"
PREFER_SYSTEM_PYTHON_FOR_ANSIBLE="1"
SYSTEM_PYTHON_MIN_MAJOR="3"
SYSTEM_PYTHON_MIN_MINOR="12"

source.release.common() {
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  if [[ -n "${script_dir}" && -r "${script_dir}/release.common.sh" ]]; then
    # shellcheck source=bootstrap/release.common.sh
    source "${script_dir}/release.common.sh"
    return
  fi
  mkdir -p "${TMP_DIR}"
  wget -qO "${COMMON_HELPER_PATH}" "${PAGES_BASE_URL}/release.common.sh" \
    || error.exit "Unable to fetch the shared release bootstrap helper."
  # shellcheck source=/tmp/proxmox-metal/release.common.sh
  source "${COMMON_HELPER_PATH}"
}

# --- Error handler ---
error.exit() {
  local msg="$1"
  log.error.fatal
  printf "%s\n" "$msg" >&2
  exit 1
}

source.release.common

# --- System checks ---
system.ensure.root() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    return
  fi
  error.exit "${MSG[fail]}"
}

system.ensure.apt() {
  if ! command -v apt-get >/dev/null 2>&1; then
    error.exit "apt-get not found; this bootstrap expects a Debian/Ubuntu-style system."
  fi
}

# --- Install ansible-core ---
install.ansible() {
  ensure.managed.ansible
  log.info "Managed Ansible ready: $("${ANSIBLE_PLAYBOOK_BIN}" --version | head -n1)"
}

# --- Fetchers ---
# --- Playbook actions ---
fetch.playbook() {
  log.info "Fetching playbook from: ${PLAYBOOK[url]}"
  wget -qO "${PLAYBOOK[path]}" "${PLAYBOOK[url]}"
  log.info "Playbook saved to: ${PLAYBOOK[path]}"
}

fetch.groupvars() {
  log.info "Fetching global group_vars from: ${GROUPVARS[url]}"
  mkdir -p "${GROUPVARS[dir]}"
  if ! wget -qO "${GROUPVARS[path]}" "${GROUPVARS[url]}"; then
    log.warn "[metal] group_vars not fetched from ${GROUPVARS[url]}"
  fi
  if [[ -s "${GROUPVARS[path]}" ]]; then
    return
  fi
}

fetch.playlist() {
  log.info "Fetching playlist from: ${PLAYLIST[url]}"
  if ! wget -qO "${PLAYLIST[path]}" "${PLAYLIST[url]}"; then
    error.exit "[metal] unable to download playlist: ${PLAYLIST[url]}"
  fi
  if [[ ! -s "${PLAYLIST[path]}" ]]; then
    error.exit "[metal] playlist is missing or empty: ${PLAYLIST[url]}"
  fi
}

# --- Runners ---
run.playbook() {
   log.info "Running Ansible playbook against localhost..."
   ansible.runtime.run -i localhost, -c local "${PLAYBOOK[path]}"
   log.info "Ansible playbook run completed."
}

run.playlist() {
  while IFS= read -r line; do
    # normalize line endings / trim trailing whitespace
    line="${line%%$'\r'}"
    line="$(printf '%s' "${line}" | sed 's/[[:space:]]*$//')"
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" != *.yml ]] && continue

    PLAYBOOK[name]="${line}"
    PLAYBOOK[url]="${GITHUB[url]}/ansible/debian/${PLAYBOOK[name]}"
    PLAYBOOK[path]="/tmp/${PLAYBOOK[name]}"
    fetch.playbook
    run.playbook
  done < "${PLAYLIST[path]}"
}


# --- Setup runner ---
run.setup() {
  log.info "Starting bootstrap..."
  system.ensure.root
  system.ensure.apt
  install.ansible
  fetch.groupvars
  fetch.playlist
  run.playlist

  log.info "${MSG[success]}"
}


run.setup "$@"
