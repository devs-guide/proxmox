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
SETUP_VLAN_RUNNER="setup/vlan.sh"
SETUP_NETWORK_RUNNER="setup/network.sh"
SETUP_CLI_CODEX_RUNNER="setup/cli.codex.sh"
SETUP_SAMBA_RUNNER="setup/lxc/samba.sh"
SETUP_DEBIAN_LXC_RUNNER="setup/lxc/debian.sh"

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
# Python deps
# -------------------------

ensure.pyyaml() {
  if python3 - <<'PY' >/dev/null 2>&1
import yaml
PY
  then
    return
  fi

  log.warn "[www.pages] PyYAML not found; installing via pip --user"
  python3 -m pip install --user --quiet PyYAML
}

merge.groupvars() {
  local platform_file="$1"
  local release_file="$2"
  local dest="$3"

  ensure.pyyaml
  python3 - "$platform_file" "$release_file" "$dest" <<'PY'
import sys, yaml, pathlib
base = pathlib.Path("ansible/group_vars/all.yml")
platform = pathlib.Path(sys.argv[1])
release = pathlib.Path(sys.argv[2])
dest = pathlib.Path(sys.argv[3])

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

merged = {}
for path in (base, platform, release):
    with path.open() as fh:
        data = yaml.safe_load(fh) or {}
    if not isinstance(data, dict):
        raise SystemExit(f"{path} did not parse to a mapping")
    merged = merge(merged, data)

dest.parent.mkdir(parents=True, exist_ok=True)
with dest.open("w") as fh:
    yaml.safe_dump(merged, fh, default_flow_style=False, sort_keys=False)
PY
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

load.setup.vlan.playbooks() {
  local runner="${PATH_TO[root]}/${SETUP_VLAN_RUNNER}"
  [[ -f "${runner}" ]] || {
    log.warn "[www.pages] ${SETUP_VLAN_RUNNER} not found; skipping setup-vlan playbook refs"
    PKGS[setup_vlan]=""
    return 0
  }

  mapfile -t _setup_vlan_items < <(
    sed -n '/^[[:space:]]*FEATURE_PLAYBOOKS=(/,/^[[:space:]]*)/p' "${runner}" \
      | grep -Eo '"[^"]+"' \
      | tr -d '"'
  )

  if ((${#_setup_vlan_items[@]} == 0)); then
    log.error "[www.pages] ERROR[whitelist]: FEATURE_PLAYBOOKS array missing/empty in ${SETUP_VLAN_RUNNER}"
    exit 1
  fi

  PKGS[setup_vlan]="${_setup_vlan_items[*]}"
}

load.setup.network.playbooks() {
  local runner="${PATH_TO[root]}/${SETUP_NETWORK_RUNNER}"
  [[ -f "${runner}" ]] || {
    log.warn "[www.pages] ${SETUP_NETWORK_RUNNER} not found; skipping setup-network playbook refs"
    PKGS[setup_network]=""
    return 0
  }

  mapfile -t _setup_network_items < <(
    sed -n '/^[[:space:]]*FEATURE_PLAYBOOKS=(/,/^[[:space:]]*)/p' "${runner}" \
      | grep -Eo '"[^"]+"' \
      | tr -d '"'
  )

  if ((${#_setup_network_items[@]} == 0)); then
    log.error "[www.pages] ERROR[whitelist]: FEATURE_PLAYBOOKS array missing/empty in ${SETUP_NETWORK_RUNNER}"
    exit 1
  fi

  PKGS[setup_network]="${_setup_network_items[*]}"
}

load.setup.cli_codex.playbooks() {
  local runner="${PATH_TO[root]}/${SETUP_CLI_CODEX_RUNNER}"
  [[ -f "${runner}" ]] || {
    log.warn "[www.pages] ${SETUP_CLI_CODEX_RUNNER} not found; skipping setup-cli-codex playbook refs"
    PKGS[setup_cli_codex]=""
    return 0
  }

  mapfile -t _setup_cli_codex_items < <(
    sed -n '/^[[:space:]]*FEATURE_PLAYBOOKS=(/,/^[[:space:]]*)/p' "${runner}" \
      | grep -Eo '"[^"]+"' \
      | tr -d '"'
  )

  if ((${#_setup_cli_codex_items[@]} == 0)); then
    log.error "[www.pages] ERROR[whitelist]: FEATURE_PLAYBOOKS array missing/empty in ${SETUP_CLI_CODEX_RUNNER}"
    exit 1
  fi

  PKGS[setup_cli_codex]="${_setup_cli_codex_items[*]}"
}

load.setup.samba.playbooks() {
  local runner="${PATH_TO[root]}/${SETUP_SAMBA_RUNNER}"
  [[ -f "${runner}" ]] || {
    log.warn "[www.pages] ${SETUP_SAMBA_RUNNER} not found; skipping setup-samba playbook refs"
    PKGS[setup_samba]=""
    return 0
  }

  mapfile -t _setup_samba_items < <(
    sed -n '/^[[:space:]]*FEATURE_PLAYBOOKS=(/,/^[[:space:]]*)/p' "${runner}" \
      | grep -Eo '"[^"]+"' \
      | tr -d '"'
  )

  if ((${#_setup_samba_items[@]} == 0)); then
    log.error "[www.pages] ERROR[whitelist]: FEATURE_PLAYBOOKS array missing/empty in ${SETUP_SAMBA_RUNNER}"
    exit 1
  fi

  PKGS[setup_samba]="${_setup_samba_items[*]}"
}

load.setup.debian_lxc.playbooks() {
  local runner="${PATH_TO[root]}/${SETUP_DEBIAN_LXC_RUNNER}"
  [[ -f "${runner}" ]] || {
    log.warn "[www.pages] ${SETUP_DEBIAN_LXC_RUNNER} not found; skipping setup-debian-lxc playbook refs"
    PKGS[setup_debian_lxc]=""
    return 0
  }

  mapfile -t _setup_debian_lxc_items < <(
    sed -n '/^[[:space:]]*FEATURE_PLAYBOOKS=(/,/^[[:space:]]*)/p' "${runner}" \
      | grep -Eo '"[^"]+"' \
      | tr -d '"'
  )

  if ((${#_setup_debian_lxc_items[@]} == 0)); then
    log.error "[www.pages] ERROR[whitelist]: FEATURE_PLAYBOOKS array missing/empty in ${SETUP_DEBIAN_LXC_RUNNER}"
    exit 1
  fi

  PKGS[setup_debian_lxc]="${_setup_debian_lxc_items[*]}"
}

load.release.playbook.refs() {
  local release_dir="$1"
  local playlist_file="${PATH_TO[root]}/ansible/release/${release_dir}/install.playbooks.txt"
  local -n out_refs="$2"

  [[ -f "${playlist_file}" ]] || return 0

  mapfile -t _release_items < <(
    sed 's/[[:space:]]*$//' "${playlist_file}" | grep -vE '^[[:space:]]*(#|$)'
  )

  local playbook_ref
  for playbook_ref in "${_release_items[@]}"; do
    [[ "${playbook_ref}" == debian/* || "${playbook_ref}" == proxmox/* ]] || continue
    out_refs["${playbook_ref}"]=1
  done
}

normalize.shared.playbook.ref() {
  local playbook_ref="$1"

  if [[ "${playbook_ref}" == */* ]]; then
    printf '%s\n' "${playbook_ref}"
    return
  fi

  printf 'debian/%s\n' "${playbook_ref}"
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

publish.release.common() {
  if [[ -f "bootstrap/release.common.sh" ]]; then
    log.info "[www.pages] installing release.common.sh"
    install -m 0755 "bootstrap/release.common.sh" "${PATH_TO[publish]}/release.common.sh"
  else
    log.warn "[www.pages] release.common.sh not found; skipping publish"
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

publish.proxmox91() {
  if [[ -f "bootstrap/release.9.1.sh" ]]; then
    log.info "[www.pages] installing 9.1.sh"
    install -m 0755 "bootstrap/release.9.1.sh" "${PATH_TO[publish]}/9.1.sh"
  else
    log.warn "[www.pages] release.9.1.sh not found; skipping 9.1.sh publish"
  fi
}

publish.setup.features() {
  if [[ -f "setup/vlan.sh" ]]; then
    log.info "[www.pages] installing setup.vlan.sh"
    install -m 0755 "setup/vlan.sh" "${PATH_TO[publish]}/setup.vlan.sh"
  else
    log.warn "[www.pages] setup/vlan.sh not found; skipping setup.vlan.sh publish"
  fi

  if [[ -f "${SETUP_CLI_CODEX_RUNNER}" ]]; then
    log.info "[www.pages] installing ${SETUP_CLI_CODEX_RUNNER} as setup.cli.codex.sh"
    install -m 0755 "${SETUP_CLI_CODEX_RUNNER}" "${PATH_TO[publish]}/setup.cli.codex.sh"
  else
    log.warn "[www.pages] ${SETUP_CLI_CODEX_RUNNER} not found; skipping setup.cli.codex.sh publish"
  fi

  if [[ -f "${SETUP_NETWORK_RUNNER}" ]]; then
    log.info "[www.pages] installing ${SETUP_NETWORK_RUNNER}"
    mkdir -p "${PATH_TO[publish]}/setup"
    install -m 0755 "${SETUP_NETWORK_RUNNER}" "${PATH_TO[publish]}/${SETUP_NETWORK_RUNNER}"
  else
    log.warn "[www.pages] ${SETUP_NETWORK_RUNNER} not found; skipping structured network runner publish"
  fi

  if [[ -f "${SETUP_SAMBA_RUNNER}" ]]; then
    log.info "[www.pages] installing ${SETUP_SAMBA_RUNNER}"
    mkdir -p "${PATH_TO[publish]}/setup/lxc"
    install -m 0755 "${SETUP_SAMBA_RUNNER}" "${PATH_TO[publish]}/${SETUP_SAMBA_RUNNER}"
  else
    log.warn "[www.pages] ${SETUP_SAMBA_RUNNER} not found; skipping structured Samba runner publish"
  fi

  if [[ -f "${SETUP_DEBIAN_LXC_RUNNER}" ]]; then
    log.info "[www.pages] installing ${SETUP_DEBIAN_LXC_RUNNER}"
    mkdir -p "${PATH_TO[publish]}/setup/lxc"
    install -m 0755 "${SETUP_DEBIAN_LXC_RUNNER}" "${PATH_TO[publish]}/${SETUP_DEBIAN_LXC_RUNNER}"
  else
    log.warn "[www.pages] ${SETUP_DEBIAN_LXC_RUNNER} not found; skipping structured Debian LXC runner publish"
  fi
}

publish.ansible() {
  log.info "[www.pages] syncing ansible whitelist"
  mkdir -p "${PATH_TO[publish]}/ansible"

  load.whitelist.ansible   # populates PKGS[ansible]
  declare -A shared_playbooks=()

  local rsync_includes=(
    "--include=${PLAYBOOKS}"          # playlist file
    "--include=config.github.yml"     # shared config consumed by bootstrap
    "--include=group_vars/"           # shared vars directory
    "--include=group_vars/all.yml"    # global vars for playbooks
    "--include=group_vars/buster.yml" # platform-specific vars for Proxmox 6/Buster
    "--include=group_vars/trixie.yml" # platform-specific vars for Proxmox 9/Trixie
    "--include=group_vars/proxmox.yml" # manual Proxmox feature defaults
    "--include=debian.packages.yml"   # package catalog (legacy path, used by 6.4 RC)
    "--include=debian/packages.yml"   # package catalog (current path under debian/)
    "--include=debian/netboot.yml"    # Debian web-reference catalog for container feature UI
    "--include=debian/ssh.yml"        # shared Debian SSH policy for LXC test-access hardening
    "--include=debian/sources.trixie.yml" # Trixie sources play for 9.1+
  )
  local playbook_to_run
  for playbook_to_run in ${PKGS[ansible]}; do
    shared_playbooks["$(normalize.shared.playbook.ref "${playbook_to_run}")"]=1
  done
  load.release.playbook.refs "6.4" shared_playbooks
  load.release.playbook.refs "9.1" shared_playbooks

  load.setup.vlan.playbooks
  for playbook_to_run in ${PKGS[setup_vlan]:-}; do
    shared_playbooks["$(normalize.shared.playbook.ref "${playbook_to_run}")"]=1
  done

  load.setup.network.playbooks
  for playbook_to_run in ${PKGS[setup_network]:-}; do
    shared_playbooks["$(normalize.shared.playbook.ref "${playbook_to_run}")"]=1
  done

  load.setup.cli_codex.playbooks
  for playbook_to_run in ${PKGS[setup_cli_codex]:-}; do
    shared_playbooks["$(normalize.shared.playbook.ref "${playbook_to_run}")"]=1
  done

  load.setup.samba.playbooks
  for playbook_to_run in ${PKGS[setup_samba]:-}; do
    shared_playbooks["$(normalize.shared.playbook.ref "${playbook_to_run}")"]=1
  done

  load.setup.debian_lxc.playbooks
  for playbook_to_run in ${PKGS[setup_debian_lxc]:-}; do
    shared_playbooks["$(normalize.shared.playbook.ref "${playbook_to_run}")"]=1
  done

  for playbook_to_run in "${!shared_playbooks[@]}"; do
    rsync_includes+=( "--include=${playbook_to_run}" )
  done
  # Also include Dell-specific playbooks if referenced
  rsync_includes+=( "--include=dell/**" )

  log.info "[www.pages] whitelist entries: ${PKGS[ansible]}"
  if [[ -n "${PKGS[setup_vlan]:-}" ]]; then
    log.info "[www.pages] setup vlan entries: ${PKGS[setup_vlan]}"
  fi
  if [[ -n "${PKGS[setup_network]:-}" ]]; then
    log.info "[www.pages] setup network entries: ${PKGS[setup_network]}"
  fi
  if [[ -n "${PKGS[setup_cli_codex]:-}" ]]; then
    log.info "[www.pages] setup cli codex entries: ${PKGS[setup_cli_codex]}"
  fi
  if [[ -n "${PKGS[setup_samba]:-}" ]]; then
    log.info "[www.pages] setup samba entries: ${PKGS[setup_samba]}"
  fi
  if [[ -n "${PKGS[setup_debian_lxc]:-}" ]]; then
    log.info "[www.pages] setup debian lxc entries: ${PKGS[setup_debian_lxc]}"
  fi

  rsync -av \
    --include='*/' \
    "${rsync_includes[@]}" \
    --exclude='*' \
    ansible/ "${PATH_TO[publish]}/ansible/"
}

publish.ansible.release64() {
  if [[ -d "ansible/release/6.4" ]]; then
    log.info "[www.pages] syncing ansible release/6.4"
    local tmpdir
    tmpdir="$(mktemp -d)"

    rsync -av ansible/release/6.4/ "${tmpdir}/"

    # Merge shared + platform + release group_vars into a single doc with leading ---
    mkdir -p "${tmpdir}/group_vars"
    ensure.pyyaml
    python3 - "$tmpdir/group_vars/all.yml" <<'PY'
import sys, yaml, pathlib
base = pathlib.Path("ansible/group_vars/all.yml")
platform = pathlib.Path("ansible/group_vars/buster.yml")
release = pathlib.Path("ansible/release/6.4/group_vars/all.yml")
dest = pathlib.Path(sys.argv[1])

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

merged = {}
for path in (base, platform, release):
    with path.open() as fh:
        data = yaml.safe_load(fh) or {}
    if not isinstance(data, dict):
        raise SystemExit(f"{path} did not parse to a mapping")
    merged = merge(merged, data)

with dest.open("w") as fh:
    yaml.safe_dump(merged, fh, default_flow_style=False, sort_keys=False)
PY

    rsync -av "${tmpdir}/" "${PATH_TO[publish]}/ansible/release/6.4/"
    rm -rf "${tmpdir}"
  else
    log.warn "[www.pages] ansible/release/6.4 not found; skipping"
  fi
}

publish.ansible.release91() {
  if [[ -d "ansible/release/9.1" ]]; then
    log.info "[www.pages] syncing ansible release/9.1"
    local tmpdir
    tmpdir="$(mktemp -d)"

    rsync -av ansible/release/9.1/ "${tmpdir}/"

    merge.groupvars "ansible/group_vars/trixie.yml" "ansible/release/9.1/group_vars/all.yml" "$tmpdir/group_vars/all.yml"

    rsync -av "${tmpdir}/" "${PATH_TO[publish]}/ansible/release/9.1/"
    rm -rf "${tmpdir}"
  else
    log.warn "[www.pages] ansible/release/9.1 not found; skipping"
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
  publish.release.common
  publish.proxmox64
  publish.proxmox91
  publish.setup.features
  publish.ansible
  publish.ansible.release64
  publish.ansible.release91

  log.info "${MSG[done]}"
}

run.pages "$@"
