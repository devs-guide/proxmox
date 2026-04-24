#!/usr/bin/env bash

require.root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log.error "Run as root."
    exit 1
  fi
}

require.apt() {
  if ! command -v apt-get >/dev/null 2>&1; then
    log.error "apt-get not found; expected Proxmox/Debian-like system."
    exit 1
  fi
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

ensure.managed.ansible() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ -x "${ANSIBLE_VENV_BIN}" ]]; then
    if "${ANSIBLE_VENV_BIN}" --version 2>/dev/null | head -n1 | grep -q "core ${ANSIBLE_CORE_VERSION}\$"; then
      ensure.managed.target.python
      log "Using existing managed Ansible: $("${ANSIBLE_VENV_BIN}" --version | head -n1)"
      return
    fi
    log "Existing managed Ansible is out of policy; rebuilding venv..."
    rm -rf "${ANSIBLE_VENV}"
  fi

  ensure.managed.target.python
  log "Creating managed Ansible venv..."
  mkdir -p "${ANSIBLE_VENV}"
  "${PYTHON_BOOTSTRAP_BIN}" -m venv "${ANSIBLE_VENV}"
  "${ANSIBLE_VENV}/bin/pip" install --upgrade pip setuptools wheel
  "${ANSIBLE_VENV}/bin/pip" install --upgrade "${ANSIBLE_CORE_SPEC}" passlib
  "${ANSIBLE_VENV}/bin/ansible-galaxy" collection install community.general:8.6.0
  log "Managed Ansible ready: $("${ANSIBLE_VENV_BIN}" --version | head -n1)"
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
  local ansible_bin="${ANSIBLE_VENV_BIN}"
  local extra_vars_args=("-e" "@${MERGED_GROUP_VARS_PATH}")
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    line="$(printf '%s' "${line}" | sed 's/[[:space:]]*$//')"
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" != *.yml ]] && continue
    fetch.playbook "${line}"

    if ! "${ansible_bin}" -i localhost, -c local "${extra_vars_args[@]}" "${TMP_DIR}/${line}"; then
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
  fetch.playlist
  fetch.groupvars
  merge.groupvars
  run.playlist
}
