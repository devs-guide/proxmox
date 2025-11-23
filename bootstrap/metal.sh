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
declare -A CONFIG
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
PLAYLIST[name]='install.playbooks.txt'
PLAYLIST[url]="${GITHUB[url]}/ansible/${PLAYLIST[name]}"
PLAYLIST[path]="/tmp/${PLAYLIST[name]}"

# --- Global group_vars (shared across playbooks) ---
GROUPVARS[dir]="/tmp/group_vars"
GROUPVARS[file]="all.yml"
GROUPVARS[url]="${GITHUB[url]}/ansible/group_vars/${GROUPVARS[file]}"
GROUPVARS[path]="${GROUPVARS[dir]}/${GROUPVARS[file]}"

# Custom published config (mirrors group_vars/all.yml content)
CONFIG[file]="config.github.yml"
CONFIG[url]="${GITHUB[url]}/ansible/${CONFIG[file]}"
CONFIG[path]="/tmp/${CONFIG[file]}"


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

# --- Error handler ---
error.exit() {
  local msg="$1"
  log.error.fatal
  printf "%s\n" "$msg" >&2
  exit 1
}

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
  if command -v ansible-playbook >/dev/null 2>&1; then
    log.info "Ansible already installed: $(ansible-playbook --version | head -n1)"
    return
  fi

  log.info "Installing ansible-core via apt..."
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y --no-install-recommends \
    ansible-core \
    python3-apt

  log.info "Ansible installed: $(ansible-playbook --version | head -n1)"
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
    log.warn "[metal] group_vars not fetched from ${GROUPVARS[url]} (will rely on config.github.yml)"
  fi
  if [[ -s "${GROUPVARS[path]}" ]]; then
    return
  fi

  log.info "[metal] attempting to fetch config file as group_vars fallback: ${CONFIG[url]}"
  if ! wget -qO "${CONFIG[path]}" "${CONFIG[url]}"; then
    error.exit "[metal] unable to download group_vars or config: ${GROUPVARS[url]} / ${CONFIG[url]}"
  fi
  if [[ ! -s "${CONFIG[path]}" ]]; then
    error.exit "[metal] config file is missing or empty: ${CONFIG[url]}"
  fi
  cp "${CONFIG[path]}" "${GROUPVARS[path]}"
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
   ansible-playbook -i localhost, -c local "${PLAYBOOK[path]}"
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
    PLAYBOOK[url]="${GITHUB[url]}/ansible/${PLAYBOOK[name]}"
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
