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
declare -A MSG

# --- GitHub metadata ---
GITHUB[user]='devs-guide'
GITHUB[repo]='proxmox'
GITHUB[url]="https://${GITHUB[user]}.github.io/${GITHUB[repo]}"

# --- Playbook metadata (init: defaults to metal.playbook.yml) ---
PLAYBOOK[name]="${PLAYBOOK_NAME:-metal.playbook.yml}"
PLAYBOOK[url]="${GITHUB[url]}/ansible/${PLAYBOOK[name]}"
PLAYBOOK[path]="/tmp/${PLAYBOOK[name]}"

# --- Playlist (whitelist) metadata ---
PLAYLIST[name]='whitelist.txt'
PLAYLIST[url]="${GITHUB[url]}/ansible/${PLAYLIST[name]}"
PLAYLIST[path]="/tmp/${PLAYLIST[name]}"



# --- Messages ---
MSG[fail]=$(cat <<EOF
[metal]: Please log in as root, then run:

  wget -qO- ${GITHUB[url]}/metal.sh | bash

Example (if you have the root password):

  su -
  wget -qO- ${GITHUB[url]}/metal.sh | bash

EOF
)

MSG[success]="[metal]: Bootstrap finished successfully."
MSG[fatal]="[metal]: Fatal error encountered"

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
    error.exit "[metal] apt-get not found; this bootstrap expects a Debian/Ubuntu-style system."
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

fetch.playlist() {
  log.info "Fetching playlist from: ${PLAYLIST[url]}"
  wget -qO "${PLAYLIST[path]}" "${PLAYLIST[url]}"
}

# --- Runners ---
run.playbook() {
   log.info "Running Ansible playbook against localhost..."
   ansible-playbook -i localhost, -c local "${PLAYBOOK[path]}"
   log.info "Ansible playbook run completed."
}

run.playlist() {
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    # only run playbooks
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
  log.info "[metal]: Starting bootstrap..."
  system.ensure.root
  system.ensure.apt
  install.ansible

  # init: bootstrap
  fetch.playbook
  run.playbook

  # order: follow-on playbooks from ansible/whitelist.txt
  fetch.playlist
  run.playlist

  log.info "${MSG[success]}"
}


run.setup "$@"
