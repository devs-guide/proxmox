#!/usr/bin/env bash
# Published GPU temperature entrypoint with bounded AMD runtime resume.
set -euo pipefail

FEATURE_CLI_FILES=(
  "temperature/gpu.sh"
)

PAGES_BASE_URL="${PROXMOX_TEMPERATURE_PAGES_BASE_URL:-https://devs-guide.github.io/proxmox}"
TMP_ROOT="${PROXMOX_TEMPERATURE_TMP_DIR:-}"
CLEAN_TMP_ROOT=0
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
HELPER=""

if [[ -z "${TMP_ROOT}" ]]; then
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pve-temperature.XXXXXX")"
  CLEAN_TMP_ROOT=1
fi

temperature.cleanup() {
  if ((CLEAN_TMP_ROOT == 1)) && [[ -n "${TMP_ROOT}" && -d "${TMP_ROOT}" ]]; then
    rm -rf "${TMP_ROOT}"
  fi
}
trap temperature.cleanup EXIT INT TERM

if [[ -n "${SCRIPT_SOURCE}" && -f "${SCRIPT_SOURCE}" ]]; then
  repo_root="$(cd "$(dirname "${SCRIPT_SOURCE}")/../.." && pwd)"
  [[ -r "${repo_root}/cli/temperature/gpu.sh" ]] && HELPER="${repo_root}/cli/temperature/gpu.sh"
fi

if [[ -z "${HELPER}" ]]; then
  HELPER="${TMP_ROOT}/cli/temperature/gpu.sh"
  mkdir -p "$(dirname "${HELPER}")"
  if command -v wget >/dev/null 2>&1; then
    wget -qO "${HELPER}.tmp" "${PAGES_BASE_URL}/cli/temperature/gpu.sh"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "${PAGES_BASE_URL}/cli/temperature/gpu.sh" -o "${HELPER}.tmp"
  else
    printf '[setup.temperature.gpu][error] wget or curl is required\n' >&2
    exit 3
  fi
  mv -f "${HELPER}.tmp" "${HELPER}"
fi

bash "${HELPER}" "$@"
