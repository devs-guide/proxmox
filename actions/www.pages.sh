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
FEATURE_MANIFEST="actions/pages.features.txt"

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

load.runner.array_from_script() {
  local runner="$1"
  local array_name="$2"
  local pkg_key="$3"
  local required="$4"
  local -a runner_items=()
  local runner_item=""

  mapfile -t runner_items < <(
    sed -n "/^[[:space:]]*${array_name}=(/,/^[[:space:]]*)/p" "${runner}" \
      | grep -Eo '"[^"]+"' \
      | tr -d '"'
  )

  if ((${#runner_items[@]} == 0)); then
    if [[ "${required}" == "1" ]]; then
      log.error "[www.pages] ERROR[whitelist]: ${array_name} array missing/empty in ${runner#${PATH_TO[root]}/}"
      exit 1
    fi
    PKGS[${pkg_key}]=""
    return 0
  fi

  for runner_item in "${runner_items[@]}"; do
    case "/${runner_item}/" in
      *'/../'*|*'//'*)
        log.error "[www.pages] ERROR[features]: unsafe ${array_name} path in ${runner#${PATH_TO[root]}/}: ${runner_item}"
        exit 1
        ;;
    esac
    [[ "${runner_item}" != /* ]] || {
      log.error "[www.pages] ERROR[features]: ${array_name} paths must be relative: ${runner_item}"
      exit 1
    }
  done

  PKGS[${pkg_key}]="${runner_items[*]}"
}

load.setup.runner.refs() {
  local runner_rel="$1"
  local pkg_key="$2"
  local runner="${PATH_TO[root]}/${runner_rel}"

  [[ -f "${runner}" ]] || {
    log.warn "[www.pages] ${runner_rel} not found; skipping runner refs"
    PKGS[${pkg_key}]=""
    PKGS[${pkg_key}_support]=""
    return 0
  }

  load.runner.array_from_script "${runner}" "FEATURE_PLAYBOOKS" "${pkg_key}" "1"
  load.runner.array_from_script "${runner}" "FEATURE_SUPPORT_FILES" "${pkg_key}_support" "0"
}

add.pkg.refs_to_shared_playbooks() {
  local pkg_key="$1"
  local -n out_refs="$2"
  local playbook_ref

  for playbook_ref in ${PKGS[${pkg_key}]:-}; do
    out_refs["$(normalize.shared.playbook.ref "${playbook_ref}")"]=1
  done
}

log.pkg.entries() {
  local pkg_key="$1"
  local label="$2"

  if [[ -n "${PKGS[${pkg_key}]:-}" ]]; then
    log.info "[www.pages] ${label}: ${PKGS[${pkg_key}]}"
  fi
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
  local resolved_publish="" resolved_root=""
  resolved_publish="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${PATH_TO[publish]}")"
  resolved_root="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${PATH_TO[root]}")"
  case "${resolved_publish}" in
    /|/tmp|/private/tmp|"${resolved_root}"|"${resolved_root}/.git"|"${resolved_root}/.github")
      log.error "[www.pages] ERROR[publish]: refusing unsafe publish target: ${resolved_publish}"
      exit 1
      ;;
    "${resolved_root}"/*)
      [[ "${resolved_publish}" == "${resolved_root}/static" ]] || {
        log.error "[www.pages] ERROR[publish]: in-repository publish target must be ${resolved_root}/static"
        exit 1
      }
      ;;
  esac
  PATH_TO[publish]="${resolved_publish}"
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

publish.ansible.runtime() {
  if [[ -f "bootstrap/ansible.runtime.sh" ]]; then
    log.info "[www.pages] installing ansible.runtime.sh"
    install -m 0755 "bootstrap/ansible.runtime.sh" "${PATH_TO[publish]}/ansible.runtime.sh"
  else
    log.error "[www.pages] bootstrap/ansible.runtime.sh not found"
    exit 1
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
  local source destination policy key cli_ref cli_source cli_destination cli_mode
  local feature_index=0

  [[ -f "${FEATURE_MANIFEST}" ]] || {
    log.error "[www.pages] ERROR[features]: missing ${FEATURE_MANIFEST}"
    exit 1
  }

  while IFS='|' read -r source destination policy; do
    [[ -n "${source}" && "${source}" != \#* ]] || continue
    [[ -n "${destination}" ]] || {
      log.error "[www.pages] ERROR[features]: ${source} has no publish destination"
      exit 1
    }
    case "${policy}" in
      feature|plain) ;;
      *)
        log.error "[www.pages] ERROR[features]: invalid dependency policy for ${source}: ${policy}"
        exit 1
        ;;
    esac
    case "/${source}/${destination}/" in
      *'/../'*|*'//'* )
        log.error "[www.pages] ERROR[features]: unsafe manifest path: ${source}|${destination}"
        exit 1
        ;;
    esac
    [[ "${source}" != /* && "${destination}" != /* ]] || {
      log.error "[www.pages] ERROR[features]: manifest paths must be repository-relative"
      exit 1
    }
    [[ -f "${source}" ]] || {
      log.error "[www.pages] ERROR[features]: declared runner is missing: ${source}"
      exit 1
    }
    mkdir -p "$(dirname "${PATH_TO[publish]}/${destination}")"
    install -m 0755 "${source}" "${PATH_TO[publish]}/${destination}"
    log.info "[www.pages] installing ${source} as ${destination}"

    [[ "${policy}" == feature ]] || continue
    key="feature_${feature_index}"
    load.runner.array_from_script "${PATH_TO[root]}/${source}" "FEATURE_CLI_FILES" "${key}_cli" "0"
    for cli_ref in ${PKGS[${key}_cli]:-}; do
      [[ "${cli_ref}" == *.sh ]] || {
        log.error "[www.pages] ERROR[features]: Bash helper must end in .sh: cli/${cli_ref}"
        exit 1
      }
      cli_source="${PATH_TO[root]}/cli/${cli_ref}"
      cli_destination="${PATH_TO[publish]}/cli/${cli_ref}"
      [[ -f "${cli_source}" ]] || {
        log.error "[www.pages] ERROR[features]: ${source} references missing cli/${cli_ref}"
        exit 1
      }
      cli_mode="0755"
      [[ "${cli_ref}" == lib/* || "${cli_ref}" == */common.sh ]] && cli_mode="0644"
      mkdir -p "$(dirname "${cli_destination}")"
      install -m "${cli_mode}" "${cli_source}" "${cli_destination}"
      log.info "[www.pages] installing cli/${cli_ref}"
    done
    feature_index=$((feature_index + 1))
  done < "${FEATURE_MANIFEST}"
}

validate.published.bash.extensions() {
  local artifact first_line relative_path

  while IFS= read -r artifact; do
    IFS= read -r first_line < "${artifact}" || first_line=""
    [[ "${first_line}" == '#!'*bash* ]] || continue
    relative_path="${artifact#${PATH_TO[publish]}/}"
    [[ "${relative_path}" == *.sh ]] || {
      log.error "[www.pages] ERROR[extension]: published Bash artifact must end in .sh: ${relative_path}"
      exit 1
    }
  done < <(find "${PATH_TO[publish]}" -type f -print)

  log.info "[www.pages] all published Bash artifacts use .sh"
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
    "--include=proxmox/common.yml"    # shared non-LXC Proxmox baseline for container imports
    "--include=proxmox/container/common.yml" # shared LXC container baseline defaults
    "--include=proxmox/container/debian.base.yml" # LXC container baseline used by debian.lxc.yml
    "--include=proxmox/container/node.yml" # LXC Codex Node wrapper (sourced via setup/lxc/codex.sh)
    "--include=proxmox/container/codex.yml" # LXC Codex wrapper (sourced via setup/lxc/codex.sh)
  )
  local playbook_to_run
  for playbook_to_run in ${PKGS[ansible]}; do
    shared_playbooks["$(normalize.shared.playbook.ref "${playbook_to_run}")"]=1
  done
  load.release.playbook.refs "6.4" shared_playbooks
  load.release.playbook.refs "9.1" shared_playbooks

  local source destination policy key feature_index=0
  while IFS='|' read -r source destination policy; do
    [[ -n "${source}" && "${source}" != \#* && "${policy}" == feature ]] || continue
    key="feature_${feature_index}"
    load.setup.runner.refs "${source}" "${key}"
    add.pkg.refs_to_shared_playbooks "${key}" shared_playbooks
    add.pkg.refs_to_shared_playbooks "${key}_support" shared_playbooks
    feature_index=$((feature_index + 1))
  done < "${FEATURE_MANIFEST}"

  for playbook_to_run in "${!shared_playbooks[@]}"; do
    rsync_includes+=( "--include=${playbook_to_run}" )
  done
  # Also include Dell-specific playbooks if referenced
  rsync_includes+=( "--include=dell/**" )

  log.info "[www.pages] whitelist entries: ${PKGS[ansible]}"

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
  publish.ansible.runtime
  publish.release.common
  publish.proxmox64
  publish.proxmox91
  publish.setup.features
  publish.ansible
  publish.ansible.release64
  publish.ansible.release91
  validate.published.bash.extensions

  log.info "${MSG[done]}"
}

run.pages "$@"
