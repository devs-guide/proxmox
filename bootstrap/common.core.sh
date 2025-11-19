#!/usr/bin/env bash
## Core config + helpers for setup/bootstrap scripts

# -------------------------
# Config (override via env)
# -------------------------

# 1 = run apt full-upgrade, 0 = skip
DO_FULL_UPGRADE="${DO_FULL_UPGRADE:-1}"

# 1 = reboot at end, 0 = do not
DO_REBOOT="${DO_REBOOT:-0}"

# Log file path
LOGFILE="${LOGFILE:-/var/log/bootstrap.log}"

# Optional hostname to set (blank = no change)
HOSTNAME_NEW="${HOSTNAME_NEW:-}"

# -------------------------
# Helpers
# -------------------------

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (or via sudo)." >&2
    exit 1
  fi
}

setup_logging() {
  # Append all stdout/stderr to LOGFILE
  mkdir -p "$(dirname "$LOGFILE")"
  touch "$LOGFILE"
  chmod 600 "$LOGFILE"

  exec > >(tee -a "$LOGFILE") 2>&1
}

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

maybe_reboot() {
  if [[ "${DO_REBOOT}" -eq 1 ]]; then
    log "Reboot requested (DO_REBOOT=1). Rebooting in 5 seconds..."
    sleep 5
    reboot
  else
    log "Reboot not requested. If kernel or core libraries were upgraded, a reboot is recommended."
  fi
}
