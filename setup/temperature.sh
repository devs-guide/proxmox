#!/usr/bin/env bash
# Read-only hardware temperature dispatcher. GPU is the only v1 component.
set -euo pipefail

PAGES_BASE_URL="${PROXMOX_TEMPERATURE_PAGES_BASE_URL:-https://devs-guide.github.io/proxmox}"
TMP_ROOT="${PROXMOX_TEMPERATURE_TMP_DIR:-}"
CLEAN_TMP_ROOT=0
COMPONENT=""
FORWARD=()

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
export PROXMOX_TEMPERATURE_TMP_DIR="${TMP_ROOT}"

while (($#)); do
  case "$1" in
    --component)
      [[ -n "${2-}" ]] || { printf '[setup.temperature][error] --component requires a value\n' >&2; exit 2; }
      COMPONENT="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: setup/temperature.sh --component gpu [GPU options]\n'
      exit 0
      ;;
    *) FORWARD+=("$1"); shift ;;
  esac
done

[[ "${COMPONENT}" == gpu ]] || {
  printf '[setup.temperature][error] v1 supports only --component gpu\n' >&2
  exit 2
}

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
RUNNER=""
if [[ -n "${SCRIPT_SOURCE}" && -f "${SCRIPT_SOURCE}" ]]; then
  local_dir="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
  [[ -r "${local_dir}/temperature/gpu.sh" ]] && RUNNER="${local_dir}/temperature/gpu.sh"
fi
if [[ -z "${RUNNER}" ]]; then
  RUNNER="${TMP_ROOT}/setup/temperature/gpu.sh"
  mkdir -p "$(dirname "${RUNNER}")"
  if command -v wget >/dev/null 2>&1; then
    wget -qO "${RUNNER}.tmp" "${PAGES_BASE_URL}/setup/temperature/gpu.sh"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "${PAGES_BASE_URL}/setup/temperature/gpu.sh" -o "${RUNNER}.tmp"
  else
    printf '[setup.temperature][error] wget or curl is required\n' >&2
    exit 3
  fi
  mv -f "${RUNNER}.tmp" "${RUNNER}"
fi

bash "${RUNNER}" "${FORWARD[@]}"
