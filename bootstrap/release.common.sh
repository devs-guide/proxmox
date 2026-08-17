#!/usr/bin/env bash

# Shared runtime defaults.
#
# The release bootstrap scripts define these before sourcing this helper, but
# feature runners such as setup/lxc/debian.sh and setup/lxc/samba.sh also source
# this file directly from GitHub Pages. Keep this helper safe under
# `set -u` by assigning conservative defaults when the caller did not provide
# them. Caller-provided values remain authoritative.
: "${PYTHON_VERSION:=3.12.3}"
: "${PYTHON_MAJOR_MINOR:=3.12}"
: "${PYTHON_SOURCE_PREFIX:=/usr/local}"
: "${PYTHON_BIN:=${PYTHON_SOURCE_PREFIX}/bin/python${PYTHON_MAJOR_MINOR}}"
: "${PYTHON_SRC_DIR:=${PYTHON_SOURCE_PREFIX}/src/Python-${PYTHON_VERSION}}"
: "${PYTHON_SRC_ARCHIVE:=${PYTHON_SRC_DIR}.tgz}"
: "${PYTHON_SRC_URL:=https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz}"
: "${ANSIBLE_VENV:=/opt/ansible-venv}"
: "${ANSIBLE_VENV_BIN:=${ANSIBLE_VENV}/bin/ansible-playbook}"
: "${ANSIBLE_CORE_VERSION:=2.20.5}"
: "${ANSIBLE_CORE_SPEC:=ansible-core==${ANSIBLE_CORE_VERSION}}"
: "${MANAGED_TARGET_PYTHON_HOME:=/opt/ansible/py312}"
: "${MANAGED_TARGET_PYTHON_PATH:=${MANAGED_TARGET_PYTHON_HOME}/bin/python}"
: "${MANAGED_TARGET_HANDOFF_MARKER:=${MANAGED_TARGET_PYTHON_HOME}/.handoff-ready}"
: "${PYTHON_BOOTSTRAP_BIN:=}"
: "${PREFER_SYSTEM_PYTHON_FOR_ANSIBLE:=0}"
: "${SYSTEM_PYTHON_MIN_MAJOR:=3}"
: "${SYSTEM_PYTHON_MIN_MINOR:=12}"

source.ansible.runtime() {
  local common_source="${BASH_SOURCE[0]:-}" common_dir="" runtime_path="" runtime_url=""

  if [[ -n "${common_source}" && -f "${common_source}" ]]; then
    common_dir="$(cd "$(dirname "${common_source}")" && pwd)"
    if [[ "$(basename "${common_dir}")" == bootstrap && -r "${common_dir}/ansible.runtime.sh" ]]; then
      # shellcheck source=bootstrap/ansible.runtime.sh
      source "${common_dir}/ansible.runtime.sh"
      return
    fi
  fi

  runtime_path="${common_dir:-${TMP_DIR:-/tmp/proxmox-ansible-runtime}}/ansible.runtime.sh"
  runtime_url="${PAGES_BASE_URL:-https://devs-guide.github.io/proxmox}/ansible.runtime.sh"
  mkdir -p "$(dirname "${runtime_path}")"
  if ! wget -qO "${runtime_path}" "${runtime_url}"; then
    log.error "Failed to fetch shared Ansible runtime helper: ${runtime_url}"
    exit 10
  fi
  # shellcheck source=/tmp/proxmox-ansible-runtime/ansible.runtime.sh
  source "${runtime_path}"
}

source.ansible.runtime

require.root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log.error "Run as root."
    exit 1
  fi
}

current.script.path() {
  local source_path="${BASH_SOURCE[1]:-${BASH_SOURCE[0]:-}}"

  case "${source_path}" in
    ""|-|/dev/fd/*|/proc/self/fd/*)
      return 1
      ;;
  esac

  if [[ -r "${source_path}" ]]; then
    readlink -f "${source_path}" 2>/dev/null || printf '%s\n' "${source_path}"
    return 0
  fi

  return 1
}

ensure.root.or.sudo.reexec() {
  local sudo_reexec_flag="${1:-0}"
  local self_url="${2:-}"
  shift 2 || true

  local script_path=""
  local -a sudo_env=()

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${sudo_reexec_flag}" == "1" ]]; then
    log.error "sudo re-entry was requested but the script is still not running as root."
    exit 1
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    log.error "This setup requires root privileges. Install sudo or run as root."
    exit 1
  fi

  log "Root privileges required; requesting sudo..."
  if ! sudo -v; then
    log.error "sudo authentication failed or was cancelled."
    exit 1
  fi

  if declare -F collect.sudo.env.args >/dev/null 2>&1; then
    collect.sudo.env.args sudo_env
  fi

  if script_path="$(current.script.path)"; then
    exec sudo -E env "${sudo_env[@]}" bash "${script_path}" "$@"
  fi

  if [[ -n "${self_url}" ]] && command -v wget >/dev/null 2>&1; then
    exec sudo -E env "${sudo_env[@]}" bash -c 'wget -qO- "$1" | bash -s -- "${@:2}"' bash "${self_url}" "$@"
  fi

  if [[ -n "${self_url}" ]] && command -v curl >/dev/null 2>&1; then
    exec sudo -E env "${sudo_env[@]}" bash -c 'curl -fsSL "$1" | bash -s -- "${@:2}"' bash "${self_url}" "$@"
  fi

  log.error "Cannot re-enter with sudo from stdin because no readable local script path or fetch helper was available."
  exit 1
}

require.apt() {
  if ! command -v apt-get >/dev/null 2>&1; then
    log.error "apt-get not found; expected Proxmox/Debian-like system."
    exit 1
  fi
}

system.python.meets.minimum() {
  local python_bin="${1:-}"
  [[ -n "${python_bin}" && -x "${python_bin}" ]] || return 1

  "${python_bin}" - "$SYSTEM_PYTHON_MIN_MAJOR" "$SYSTEM_PYTHON_MIN_MINOR" <<'PY' >/dev/null 2>&1
import sys

major = int(sys.argv[1])
minor = int(sys.argv[2])
sys.exit(0 if sys.version_info[:2] >= (major, minor) else 1)
PY
}

ensure.python.venv.support() {
  local python_bin="${1:-}"
  local python_mm=""

  [[ -n "${python_bin}" && -x "${python_bin}" ]] || return 1

  if "${python_bin}" -m ensurepip --version >/dev/null 2>&1; then
    return 0
  fi

  python_mm="$("${python_bin}" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
  log "Installing venv support for system Python ${python_mm}..."
  apt-get update -y
  apt-get install -y --no-install-recommends \
    "python${python_mm}-venv"

  "${python_bin}" -m ensurepip --version >/dev/null 2>&1
}

select.ansible.bootstrap.python() {
  local system_python=""

  if [[ "${PREFER_SYSTEM_PYTHON_FOR_ANSIBLE}" == "1" ]] && command -v python3 >/dev/null 2>&1; then
    system_python="$(command -v python3)"
    if system.python.meets.minimum "${system_python}"; then
      ensure.python.venv.support "${system_python}"
      PYTHON_BOOTSTRAP_BIN="${system_python}"
      log "Using native system Python for Ansible bootstrap: $("${PYTHON_BOOTSTRAP_BIN}" --version 2>&1)"
      return
    fi
  fi

  ensure.managed.target.python
}

ansible.version.line.matches.policy() {
  local version_line="${1:-}"
  ansible.runtime.version.line.matches.policy "${version_line}"
}

ansible.venv.matches.policy() {
  local version_output=""
  local version_line=""

  [[ -x "${ANSIBLE_VENV_BIN}" ]] || return 1
  version_output="$("${ANSIBLE_VENV_BIN}" --version 2>/dev/null)" || return 1
  version_line="${version_output%%$'\n'*}"

  ansible.version.line.matches.policy "${version_line}"
}

ensure.python312() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v "python${PYTHON_MAJOR_MINOR}" >/dev/null 2>&1; then
    PYTHON_BOOTSTRAP_BIN="$(command -v "python${PYTHON_MAJOR_MINOR}")"
    log "Using existing system Python: $("${PYTHON_BOOTSTRAP_BIN}" --version 2>&1)"
    return
  fi

  if [[ -x "${PYTHON_BIN}" ]]; then
    PYTHON_BOOTSTRAP_BIN="${PYTHON_BIN}"
    log "Using existing local Python: $("${PYTHON_BOOTSTRAP_BIN}" --version 2>&1)"
    return
  fi

  log "Installing Python ${PYTHON_VERSION} build prerequisites..."
  apt-get update -y
  apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    libncursesw5-dev \
    tk-dev \
    libgdbm-dev \
    libgdbm-compat-dev \
    liblzma-dev \
    libffi-dev \
    uuid-dev \
    wget \
    curl \
    ca-certificates \
    xz-utils

  mkdir -p "${PYTHON_SOURCE_PREFIX}/src"
  if [[ ! -s "${PYTHON_SRC_ARCHIVE}" ]]; then
    log "Downloading Python ${PYTHON_VERSION} source..."
    wget -qO "${PYTHON_SRC_ARCHIVE}" "${PYTHON_SRC_URL}"
  fi

  if [[ ! -d "${PYTHON_SRC_DIR}" ]]; then
    log "Unpacking Python ${PYTHON_VERSION} source..."
    tar -xzf "${PYTHON_SRC_ARCHIVE}" -C "${PYTHON_SOURCE_PREFIX}/src"
  fi

  log "Building Python ${PYTHON_VERSION}..."
  (
    cd "${PYTHON_SRC_DIR}"
    ./configure --enable-optimizations --with-ensurepip=install
    make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    make altinstall
  )

  PYTHON_BOOTSTRAP_BIN="${PYTHON_BIN}"
}

ensure.managed.target.python() {
  local managed_version marker_path
  marker_path="${MANAGED_TARGET_HANDOFF_MARKER:-${MANAGED_TARGET_PYTHON_HOME}/.handoff-ready}"

  if [[ -x "${MANAGED_TARGET_PYTHON_PATH}" ]]; then
    if managed_version="$("${MANAGED_TARGET_PYTHON_PATH}" --version 2>&1)"; then
      log "Using existing managed target Python: ${managed_version}"
      printf '%s\n' "${managed_version}" > "${marker_path}"
      PYTHON_BOOTSTRAP_BIN="${MANAGED_TARGET_PYTHON_PATH}"
      return
    fi
    log "Existing managed target Python is invalid; rebuilding environment..."
    rm -rf "${MANAGED_TARGET_PYTHON_HOME}"
  fi

  ensure.python312
  log "Creating managed target Python environment..."
  mkdir -p "$(dirname "${MANAGED_TARGET_PYTHON_HOME}")"
  "${PYTHON_BOOTSTRAP_BIN}" -m venv "${MANAGED_TARGET_PYTHON_HOME}"
  managed_version="$("${MANAGED_TARGET_PYTHON_PATH}" --version 2>&1)"
  printf '%s\n' "${managed_version}" > "${marker_path}"
  PYTHON_BOOTSTRAP_BIN="${MANAGED_TARGET_PYTHON_PATH}"
}

ensure.container.python() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BOOTSTRAP_BIN="$(command -v python3)"
    log "Using existing container system Python: $("${PYTHON_BOOTSTRAP_BIN}" --version 2>&1)"
    return
  fi

  log "Installing container Python runtime prerequisites..."
  apt-get update -y
  apt-get install -y --no-install-recommends \
    python3 \
    python3-venv \
    python3-apt \
    ca-certificates

  if ! command -v python3 >/dev/null 2>&1; then
    log.error "python3 is still unavailable after installing container runtime prerequisites."
    exit 1
  fi

  PYTHON_BOOTSTRAP_BIN="$(command -v python3)"
  log "Using installed container system Python: $("${PYTHON_BOOTSTRAP_BIN}" --version 2>&1)"
}

ensure.managed.ansible() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ -x "${ANSIBLE_VENV_BIN}" ]]; then
    if ansible.venv.matches.policy; then
      select.ansible.bootstrap.python
      ansible.runtime.require
      log "Using existing managed Ansible: $("${ANSIBLE_VENV_BIN}" --version | head -n1)"
      return
    fi
    log "Existing managed Ansible is out of policy; rebuilding venv..."
    rm -rf "${ANSIBLE_VENV}"
  fi

  select.ansible.bootstrap.python
  log "Creating managed Ansible venv..."
  mkdir -p "${ANSIBLE_VENV}"
  "${PYTHON_BOOTSTRAP_BIN}" -m venv "${ANSIBLE_VENV}"
  "${ANSIBLE_VENV}/bin/pip" install --upgrade pip setuptools wheel
  "${ANSIBLE_VENV}/bin/pip" install --upgrade "${ANSIBLE_CORE_SPEC}" passlib
  "${ANSIBLE_VENV}/bin/ansible-galaxy" collection install community.general:8.6.0
  ansible.runtime.require
  log "Managed Ansible ready: $("${ANSIBLE_VENV_BIN}" --version | head -n1)"
}

ensure.container.ansible() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ -x "${ANSIBLE_VENV_BIN}" ]]; then
    if ansible.venv.matches.policy; then
      ensure.container.python
      ansible.runtime.require
      log "Using existing container Ansible: $("${ANSIBLE_VENV_BIN}" --version | head -n1)"
      return
    fi
    log "Existing container Ansible is out of policy; rebuilding venv..."
    rm -rf "${ANSIBLE_VENV}"
  fi

  ensure.container.python

  if ! "${PYTHON_BOOTSTRAP_BIN}" -m ensurepip --version >/dev/null 2>&1; then
    log "Installing python3-venv for container runtime..."
    apt-get update -y
    apt-get install -y --no-install-recommends python3-venv
  fi

  if [[ -d "${ANSIBLE_VENV}" && ! -x "${ANSIBLE_VENV_BIN}" ]]; then
    log "Removing incomplete container Ansible venv before rebuild..."
    rm -rf "${ANSIBLE_VENV}"
  fi

  log "Creating container Ansible venv..."
  mkdir -p "${ANSIBLE_VENV}"
  "${PYTHON_BOOTSTRAP_BIN}" -m venv "${ANSIBLE_VENV}"
  "${ANSIBLE_VENV}/bin/pip" install --upgrade pip setuptools wheel
  "${ANSIBLE_VENV}/bin/pip" install --upgrade "${ANSIBLE_CORE_SPEC}" passlib
  "${ANSIBLE_VENV}/bin/ansible-galaxy" collection install community.general:8.6.0
  ansible.runtime.require
  log "Container Ansible ready: $("${ANSIBLE_VENV_BIN}" --version | head -n1)"
}

fetch.playlist() {
  mkdir -p "${TMP_DIR}"
  log "Fetching playlist: ${PLAYLIST_URL}"
  if ! wget -qO "${PLAYLIST_PATH}" "${PLAYLIST_URL}"; then
    log.error "Failed to fetch playlist: ${PLAYLIST_URL}"
    exit 1
  fi
  if [[ ! -s "${PLAYLIST_PATH}" ]]; then
    log.error "Playlist is empty: ${PLAYLIST_URL}"
    exit 1
  fi
}

fetch.groupvars() {
  mkdir -p "${GROUP_VARS_DIR}"
  log "Fetching base group_vars: ${BASE_GROUP_VARS_URL}"
  if ! wget -qO "${BASE_GROUP_VARS_PATH}" "${BASE_GROUP_VARS_URL}"; then
    log.error "Failed to fetch base group_vars: ${BASE_GROUP_VARS_URL}"
    exit 1
  fi
  if [[ ! -s "${BASE_GROUP_VARS_PATH}" ]]; then
    log.error "Base group_vars is empty: ${BASE_GROUP_VARS_URL}"
    exit 1
  fi

  log "Fetching ${PLATFORM_GROUP_VARS_LABEL} group_vars: ${PLATFORM_GROUP_VARS_URL}"
  if ! wget -qO "${PLATFORM_GROUP_VARS_PATH}" "${PLATFORM_GROUP_VARS_URL}"; then
    log.error "Failed to fetch ${PLATFORM_GROUP_VARS_LABEL} group_vars: ${PLATFORM_GROUP_VARS_URL}"
    exit 1
  fi
  if [[ ! -s "${PLATFORM_GROUP_VARS_PATH}" ]]; then
    log.error "${PLATFORM_GROUP_VARS_LOG_LABEL} group_vars is empty: ${PLATFORM_GROUP_VARS_URL}"
    exit 1
  fi

  log "Fetching release group_vars: ${GROUP_VARS_URL}"
  if ! wget -qO "${GROUP_VARS_PATH}" "${GROUP_VARS_URL}"; then
    log.error "Failed to fetch release group_vars: ${GROUP_VARS_URL}"
    exit 1
  fi
  if [[ ! -s "${GROUP_VARS_PATH}" ]]; then
    log.error "Release group_vars is empty: ${GROUP_VARS_URL}"
    exit 1
  fi
}

merge.groupvars() {
  log "Merging group_vars (base + ${PLATFORM_GROUP_VARS_LABEL} + release)..."
  if ! python3 - <<'PY' >/dev/null 2>&1
import yaml
PY
  then
    log "Installing python3-yaml for merge support..."
    apt-get update -y
    apt-get install -y --no-install-recommends python3-yaml
  fi

  python3 - "$BASE_GROUP_VARS_PATH" "$PLATFORM_GROUP_VARS_PATH" "$GROUP_VARS_PATH" "$MERGED_GROUP_VARS_PATH" <<'PY'
import sys, yaml

def merge(a, b):
    if not isinstance(a, dict) or not isinstance(b, dict):
        return b
    out = dict(a)
    for k, v in b.items():
        if k in out:
            out[k] = merge(out[k], v)
        else:
            out[k] = v
    return out

paths = sys.argv[1:-1]
dest = sys.argv[-1]
merged = {}
for path in paths:
    with open(path, "r") as fh:
        data = yaml.safe_load(fh) or {}
    if data is None:
        data = {}
    if not isinstance(data, dict):
        raise SystemExit(f"{path} did not parse to a mapping")
    merged = merge(merged, data)

with open(dest, "w") as fh:
    yaml.safe_dump(merged, fh, default_flow_style=False)
PY
  log "Merged group_vars written to ${MERGED_GROUP_VARS_PATH}"
}

fetch.playbook() {
  local name="$1"
  local url dest

  if [[ "${name}" == debian/* ]]; then
    url="${DEBIAN_BASE_URL}/${name#debian/}"
    dest="${TMP_DIR}/debian/${name#debian/}"
  elif [[ "${name}" == dell/* ]]; then
    url="${DELL_BASE_URL}/${name#dell/}"
    dest="${TMP_DIR}/dell/${name#dell/}"
  else
    url="${BASE_URL}/${name}"
    dest="${TMP_DIR}/${name}"
  fi

  mkdir -p "$(dirname "${dest}")"
  log "Fetching playbook: ${url}"
  if ! wget -qO "${dest}" "${url}"; then
    log.error "Failed to fetch playbook: ${url}"
    exit 1
  fi
  if [[ ! -s "${dest}" ]]; then
    log.error "Playbook is empty: ${url}"
    exit 1
  fi
}

run.playlist() {
  log "Running ${RELEASE_LABEL} playlist via ansible..."
  local extra_vars_args=("-e" "@${MERGED_GROUP_VARS_PATH}")
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    line="$(printf '%s' "${line}" | sed 's/[[:space:]]*$//')"
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" != *.yml ]] && continue
    fetch.playbook "${line}"

    if ! ansible.runtime.run -i localhost, -c local "${extra_vars_args[@]}" "${TMP_DIR}/${line}"; then
      log.error "Ansible failed on playbook: ${line}"
      exit 1
    fi
  done < "${PLAYLIST_PATH}"
  log "Ansible playlist complete."
}

maybe.run.ansible() {
  if [[ "${SKIP_ANSIBLE:-0}" == "1" ]]; then
    log "SKIP_ANSIBLE=1 set; skipping ansible playlist."
    return
  fi
  ensure.managed.ansible
  # The controller may use native system Python, but playlist modules retain
  # the release-managed target interpreter contract.
  ensure.managed.target.python
  fetch.playlist
  fetch.groupvars
  merge.groupvars
  run.playlist
}
