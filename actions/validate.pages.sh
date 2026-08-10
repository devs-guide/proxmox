#!/usr/bin/env bash
set -euo pipefail

# Artifact drift check supports two modes:
#   remote (default): fetch published Pages artifacts and diff against working tree.
#   local: compare working tree against generated static/ artifacts.
BASE_URL="${BASE_URL:-https://devs-guide.github.io/proxmox}"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_DIR="${STATIC_DIR:-${WORKDIR}/static}"
VALIDATE_PAGES_MODE="${VALIDATE_PAGES_MODE:-remote}"
VALIDATE_PAGES_GRAPH_ONLY="${VALIDATE_PAGES_GRAPH_ONLY:-0}"
TMPDIR="$(mktemp -d)"
if [[ "${VALIDATE_PAGES_MODE}" != "local" && "${VALIDATE_PAGES_MODE}" != "remote" ]]; then
  echo "[validate.pages][error] invalid VALIDATE_PAGES_MODE=${VALIDATE_PAGES_MODE}; must be local|remote"
  exit 1
fi

fetch_artifact() {
  local remote_path="$1"
  local dest="$2"

  mkdir -p "$(dirname "${dest}")"

  if [[ "${VALIDATE_PAGES_MODE}" == "local" ]]; then
    local local_path="${STATIC_DIR}/${remote_path}"
    if [[ ! -f "${local_path}" ]]; then
      echo "[validate.pages][error] missing generated static artifact: ${local_path}"
      return 1
    fi
    cp "${local_path}" "${dest}"
    return 0
  fi

  local url="${BASE_URL}/${remote_path}"
  echo "[validate.pages] fetch ${url}"
  if ! curl -fsSL "${url}" -o "${dest}"; then
    echo "[validate.pages][error] failed to fetch ${url}"
    return 1
  fi
}

is.true() {
  local value="${1:-}"
  case "${value,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

echo "[validate.pages] mode: ${VALIDATE_PAGES_MODE}"
if [[ "${VALIDATE_PAGES_MODE}" == "local" ]]; then
  echo "[validate.pages] static dir: ${STATIC_DIR}"
else
  echo "[validate.pages] using BASE_URL=${BASE_URL}"
fi
echo "[validate.pages] temp dir: ${TMPDIR}"

# Keep this list synced with runner dependencies and pages publish expectations.
FILES=(
  "6.4.sh:bootstrap/release.6.4.sh"
  "9.1.sh:bootstrap/release.9.1.sh"
  "release.common.sh:bootstrap/release.common.sh"
  "setup.vlan.sh:setup/vlan.sh"
  "setup/network.sh:setup/network.sh"
  "setup.cli.codex.sh:setup/cli.codex.sh"
  "setup/lxc/debian.sh:setup/lxc/debian.sh"
  "setup/lxc/common.sh:setup/lxc/common.sh"
  "setup/lxc/samba.sh:setup/lxc/samba.sh"
  "setup/lxc/network.sh:setup/lxc/network.sh"
  "setup/lxc/codex.sh:setup/lxc/codex.sh"
  "setup/lxc/users.sh:setup/lxc/users.sh"
  "ansible/proxmox/common.yml:ansible/proxmox/common.yml"
  "ansible/proxmox/container/common.yml:ansible/proxmox/container/common.yml"
  "ansible/proxmox/container/debian.lxc.yml:ansible/proxmox/container/debian.lxc.yml"
  "ansible/proxmox/container/debian.yml:ansible/proxmox/container/debian.yml"
  "ansible/proxmox/container/debian.base.yml:ansible/proxmox/container/debian.base.yml"
  "ansible/proxmox/container/node.yml:ansible/proxmox/container/node.yml"
  "ansible/proxmox/container/codex.yml:ansible/proxmox/container/codex.yml"
  "ansible/proxmox/container/users.yml:ansible/proxmox/container/users.yml"
  "ansible/proxmox/container/samba.file.share.yml:ansible/proxmox/container/samba.file.share.yml"
  "ansible/proxmox/container/network.access.yml:ansible/proxmox/container/network.access.yml"
  "ansible/debian/install.packages.yml:ansible/debian/install.packages.yml"
  "ansible/debian/node.yml:ansible/debian/node.yml"
  "ansible/debian/cli.codex.yml:ansible/debian/cli.codex.yml"
  "ansible/debian/users.yml:ansible/debian/users.yml"
  "ansible/debian/netboot.yml:ansible/debian/netboot.yml"
  "ansible/debian/packages.yml:ansible/debian/packages.yml"
  "ansible/debian/ssh.yml:ansible/debian/ssh.yml"
  "ansible/debian/sources.trixie.yml:ansible/debian/sources.trixie.yml"
  "ansible/group_vars/proxmox.yml:ansible/group_vars/proxmox.yml"
  "ansible/group_vars/trixie.yml:ansible/group_vars/trixie.yml"
  "ansible/release/9.1/enterprise.yml:ansible/release/9.1/enterprise.yml"
)

GENERATED_FILES=(
  "ansible/release/9.1/group_vars/all.yml:ansible/release/9.1/group_vars/all.yml"
)

rc=0
if ! is.true "${VALIDATE_PAGES_GRAPH_ONLY}"; then
  for entry in "${FILES[@]}"; do
    remote_path="${entry%%:*}"
    local_path="${entry#*:}"
    dest="${TMPDIR}/${remote_path}"
    mkdir -p "$(dirname "${dest}")"

    if ! fetch_artifact "${remote_path}" "${dest}"; then
      rc=1
      continue
    fi

    if ! diff -u "${WORKDIR}/${local_path}" "${dest}" >/dev/null; then
      if [[ "${VALIDATE_PAGES_MODE}" == "local" ]]; then
        echo "[validate.pages][diff] ${local_path} differs from generated ${STATIC_DIR}/${remote_path}"
      else
        echo "[validate.pages][diff] ${local_path} differs from published ${BASE_URL}/${remote_path}"
      fi
      diff -u "${WORKDIR}/${local_path}" "${dest}" || true
      rc=1
    else
      if [[ "${VALIDATE_PAGES_MODE}" == "local" ]]; then
        echo "[validate.pages][ok] ${local_path} matches generated ${STATIC_DIR}/${remote_path}"
      else
        echo "[validate.pages][ok] ${local_path} matches published ${BASE_URL}/${remote_path}"
      fi
    fi
  done
fi

read.runner.array() {
  local runner_path="$1"
  local array_name="$2"
  local required="$3"
  local feature_ref=""

  RUNNER_ARRAY_REFS=()
  while IFS= read -r feature_ref; do
    [[ -n "${feature_ref}" ]] || continue
    RUNNER_ARRAY_REFS+=("${feature_ref}")
  done < <(
    sed -n "/^[[:space:]]*${array_name}=(/,/^[[:space:]]*)/p" "${runner_path}" \
      | grep -Eo '"[^"]+"' \
      | tr -d '"'
  )

  if ((${#RUNNER_ARRAY_REFS[@]} == 0)) && [[ "${required}" == "1" ]]; then
    echo "[validate.pages][error] ${runner_path#${WORKDIR}/} has empty or missing ${array_name} array"
    rc=1
    return 1
  fi

  return 0
}

check_artifact_ref() {
  local runner_rel="$1"
  local feature_ref="$2"
  local local_playbook="ansible/${feature_ref}"
  local remote_playbook="${local_playbook}"
  local tmp_playbook="${TMPDIR}/${remote_playbook}"
  local compare_hint=""

  if [[ ! -f "${WORKDIR}/${local_playbook}" ]]; then
    echo "[validate.pages][error] ${runner_rel} references missing local artifact: ${local_playbook}"
    rc=1
    return 1
  fi

  if ! fetch_artifact "${remote_playbook}" "${tmp_playbook}"; then
    if [[ "${VALIDATE_PAGES_MODE}" == "local" ]]; then
      echo "[validate.pages][error] failed to fetch setup dependency ${STATIC_DIR}/${remote_playbook}"
    else
      echo "[validate.pages][error] failed to fetch setup dependency ${BASE_URL}/${remote_playbook}"
    fi
    rc=1
    return 1
  fi

  if [[ "${VALIDATE_PAGES_MODE}" == "local" ]]; then
    compare_hint="${STATIC_DIR}/${remote_playbook}"
  else
    compare_hint="${BASE_URL}/${remote_playbook}"
  fi

  if ! diff -u "${WORKDIR}/${local_playbook}" "${tmp_playbook}" >/dev/null; then
    echo "[validate.pages][diff] ${local_playbook} differs from ${compare_hint}"
    diff -u "${WORKDIR}/${local_playbook}" "${tmp_playbook}" || true
    rc=1
    return 1
  fi

  echo "[validate.pages][ok] ${local_playbook} matches ${compare_hint}"
}

normalize.rel.path() {
  local path="$1"
  local -a parts=()
  local -a normalized=()
  local part=""

  IFS='/' read -r -a parts <<< "${path}"
  for part in "${parts[@]}"; do
    case "${part}" in
      ""|.) ;;
      ..)
        if ((${#normalized[@]} > 0)); then
          unset "normalized[${#normalized[@]}-1]"
        fi
        ;;
      *)
        normalized+=("${part}")
        ;;
    esac
  done

  (IFS='/'; printf '%s\n' "${normalized[*]}")
}

resolve.wrapper.dep.path() {
  local wrapper_rel="$1"
  local dep_rel="$2"
  dep_rel="${dep_rel#/}"
  normalize.rel.path "$(dirname "${wrapper_rel}")/${dep_rel}"
}

check_setup_feature_refs() {
  local runner_rel="$1"
  local runner_path="${WORKDIR}/${runner_rel}"
  local feature_ref=""
  local -a playbook_refs=()
  local -a support_refs=()
  local -a setup_feature_refs=()

  if [[ ! -f "${runner_path}" ]]; then
    echo "[validate.pages][error] missing local setup runner: ${runner_path}"
    rc=1
    return
  fi

  if ! read.runner.array "${runner_path}" "FEATURE_PLAYBOOKS" "1"; then
    return
  fi
  playbook_refs=( "${RUNNER_ARRAY_REFS[@]}" )

  read.runner.array "${runner_path}" "FEATURE_SUPPORT_FILES" "0" || true
  support_refs=( "${RUNNER_ARRAY_REFS[@]}" )
  setup_feature_refs=( "${playbook_refs[@]}" "${support_refs[@]}" )

  for feature_ref in "${setup_feature_refs[@]}"; do
    check_artifact_ref "${runner_rel}" "${feature_ref}" || true
  done
}

check_wrapper_dependency_graph() {
  local wrapper_rel="$1"
  local wrapper_tmp="${TMPDIR}/${wrapper_rel}"
  local dep_rel=""
  local resolved_rel=""
  local resolved_tmp=""

  if ! fetch_artifact "${wrapper_rel}" "${wrapper_tmp}"; then
    echo "[validate.pages][error] failed to fetch wrapper dependency root ${wrapper_rel}"
    rc=1
    return
  fi

  while IFS= read -r dep_rel; do
    [[ -n "${dep_rel}" ]] || continue
    resolved_rel="$(resolve.wrapper.dep.path "${wrapper_rel}" "${dep_rel}")"
    resolved_tmp="${TMPDIR}/${resolved_rel}"
    if ! fetch_artifact "${resolved_rel}" "${resolved_tmp}"; then
      echo "[validate.pages][error] wrapper dependency missing from published tree: ${wrapper_rel} -> ${dep_rel} -> ${resolved_rel}"
      rc=1
    fi
  done < <(sed -n 's/^[[:space:]-]*import_playbook:[[:space:]]*//p' "${wrapper_tmp}" | sed 's/[[:space:]]*$//')

  while IFS= read -r dep_rel; do
    [[ -n "${dep_rel}" ]] || continue
    resolved_rel="$(resolve.wrapper.dep.path "${wrapper_rel}" "${dep_rel}")"
    resolved_tmp="${TMPDIR}/${resolved_rel}"
    if ! fetch_artifact "${resolved_rel}" "${resolved_tmp}"; then
      echo "[validate.pages][error] wrapper file lookup missing from published tree: ${wrapper_rel} -> ${dep_rel} -> ${resolved_rel}"
      rc=1
    fi
  done < <(sed -n "s/.*playbook_dir ~ '\\([^']\\+\\)'.*/\\1/p" "${wrapper_tmp}")
}

check_generated_file_artifacts() {
  local entry
  local remote_path
  local local_path
  local tmp_artifact

  for entry in "${GENERATED_FILES[@]}"; do
    remote_path="${entry%%:*}"
    local_path="${entry#*:}"
    tmp_artifact="${TMPDIR}/${remote_path}"

    if [[ "${VALIDATE_PAGES_MODE}" == "local" ]]; then
      local artifact_path="${STATIC_DIR}/${remote_path}"
      if [[ ! -f "${artifact_path}" ]]; then
        echo "[validate.pages][error] missing generated static artifact: ${artifact_path}"
        rc=1
      fi
      if [[ ! -f "${artifact_path}" ]]; then
        continue
      fi
      mkdir -p "$(dirname "${tmp_artifact}")"
      if ! cp "${artifact_path}" "${tmp_artifact}"; then
        echo "[validate.pages][error] failed to read generated static artifact: ${artifact_path}"
        rc=1
        continue
      fi
      echo "[validate.pages][ok] generated artifact exists in static build: ${artifact_path}"
    else
      if ! fetch_artifact "${remote_path}" "${tmp_artifact}"; then
        rc=1
        continue
      fi
      echo "[validate.pages][ok] generated artifact exists on published Pages: ${BASE_URL}/${remote_path}"
    fi

    if [[ ! -f "${WORKDIR}/${local_path}" ]]; then
      echo "[validate.pages][error] missing local source for generated artifact: ${local_path}"
      rc=1
      continue
    fi
  done
}

check_playlist_refs() {
  local playlist_path="$1"
  local remote_playlist="${playlist_path}"
  local tmp_playlist="${TMPDIR}/${remote_playlist}"

  if ! fetch_artifact "${remote_playlist}" "${tmp_playlist}"; then
    echo "[validate.pages][error] failed to fetch ${BASE_URL}/${remote_playlist}"
    rc=1
    return
  fi

  if ! diff -u "${WORKDIR}/${playlist_path}" "${tmp_playlist}" >/dev/null; then
    if [[ "${VALIDATE_PAGES_MODE}" == "local" ]]; then
      echo "[validate.pages][diff] ${playlist_path} differs from generated ${STATIC_DIR}/${remote_playlist}"
    else
      echo "[validate.pages][diff] ${playlist_path} differs from published ${BASE_URL}/${remote_playlist}"
    fi
    diff -u "${WORKDIR}/${playlist_path}" "${tmp_playlist}" || true
    rc=1
  else
    if [[ "${VALIDATE_PAGES_MODE}" == "local" ]]; then
      echo "[validate.pages][ok] ${playlist_path} matches generated ${STATIC_DIR}/${remote_playlist}"
    else
      echo "[validate.pages][ok] ${playlist_path} matches published ${BASE_URL}/${remote_playlist}"
    fi
  fi

  while IFS= read -r playbook_ref; do
    [[ -n "${playbook_ref}" ]] || continue
    [[ "${playbook_ref}" =~ ^[[:space:]]*# ]] && continue
    if [[ ! -f "${WORKDIR}/ansible/release/$(dirname "${playlist_path##ansible/release/}")/${playbook_ref}" && ! -f "${WORKDIR}/ansible/${playbook_ref}" ]]; then
      echo "[validate.pages][error] playlist entry missing locally: ${playlist_path} -> ${playbook_ref}"
      rc=1
      continue
    fi

    local remote_playbook="ansible/${playbook_ref}"
    if [[ ! "${playbook_ref}" == debian/* && ! "${playbook_ref}" == proxmox/* ]]; then
      local release_dir
      release_dir="$(basename "$(dirname "${playlist_path}")")"
      remote_playbook="ansible/release/${release_dir}/${playbook_ref}"
    fi

    local tmp_playbook="${TMPDIR}/${remote_playbook}"
    if ! fetch_artifact "${remote_playbook}" "${tmp_playbook}"; then
      echo "[validate.pages][error] failed to fetch referenced playbook ${BASE_URL}/${remote_playbook}"
      rc=1
      continue
    fi
  done < <(sed 's/[[:space:]]*$//' "${WORKDIR}/${playlist_path}" | grep -vE '^[[:space:]]*(#|$)')
}

if ! is.true "${VALIDATE_PAGES_GRAPH_ONLY}"; then
  check_playlist_refs "ansible/release/6.4/install.playbooks.txt"
  check_playlist_refs "ansible/release/9.1/install.playbooks.txt"
fi
check_setup_feature_refs "setup/vlan.sh"
check_setup_feature_refs "setup/network.sh"
check_setup_feature_refs "setup/cli.codex.sh"
check_setup_feature_refs "setup/lxc/debian.sh"
check_setup_feature_refs "setup/lxc/samba.sh"
check_setup_feature_refs "setup/lxc/network.sh"
check_setup_feature_refs "setup/lxc/codex.sh"
check_setup_feature_refs "setup/lxc/users.sh"
check_wrapper_dependency_graph "ansible/proxmox/container/node.yml"
check_wrapper_dependency_graph "ansible/proxmox/container/codex.yml"
check_wrapper_dependency_graph "ansible/proxmox/container/users.yml"
check_wrapper_dependency_graph "ansible/proxmox/container/debian.yml"
check_wrapper_dependency_graph "ansible/proxmox/container/debian.base.yml"

check_published_samba_runner_policy() {
  local published_runner="${TMPDIR}/setup/lxc/samba.sh"
  local needle

  if [[ ! -f "${published_runner}" ]]; then
    echo "[validate.pages][error] published setup/lxc/samba.sh was not fetched"
    rc=1
    return
  fi

  for needle in \
    'ensure.container.ansible' \
    'Container Ansible ready' \
    'Using existing container system Python' \
    'Continue with Samba base setup and no shares' \
    'findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS' \
    'Select shares: single `4`, range `1-5`, CSV `1,4,6`, mixed `1-4,7`, `ALL`, or `NONE`' \
    'PROXMOX_SAMBA_MAP_TO_GUEST' \
    'PROXMOX_SAMBA_GUEST_ACCOUNT' \
    'writable: %s' \
    'ensurepip --version'; do
    if ! grep -q -- "${needle}" "${published_runner}" && ! grep -q -- "${needle}" "${TMPDIR}/release.common.sh"; then
      echo "[validate.pages][error] published Samba/container runtime path is stale or missing marker: ${needle}"
      rc=1
    fi
  done
  if grep -q 'ensure.managed.ansible' "${published_runner}"; then
    echo "[validate.pages][error] published setup/lxc/samba.sh still uses the heavy managed-target Ansible bootstrap path"
    rc=1
  fi
}

check_published_release91_bootstrap_policy() {
  local published_bootstrap="${TMPDIR}/9.1.sh"
  local published_common="${TMPDIR}/release.common.sh"
  local published_enterprise="${TMPDIR}/ansible/release/9.1/enterprise.yml"
  local playlist_runner_body=""
  local managed_ansible_line=""
  local managed_target_line=""
  local fetch_playlist_line=""
  local run_playlist_line=""
  local needle

  if [[ ! -f "${published_bootstrap}" ]]; then
    echo "[validate.pages][error] published 9.1.sh was not fetched"
    rc=1
    return
  fi

  for needle in \
    'disable.enterprise.sources()' \
    'Disabling Proxmox enterprise apt sources before bootstrap update' \
    "enterprise\\.proxmox\\.com/debian/(pve|ceph)" \
    'ceph.release.gpg' \
    'PREFER_SYSTEM_PYTHON_FOR_ANSIBLE="1"' \
    'SYSTEM_PYTHON_MIN_MINOR="12"'; do
    if ! grep -Fq -- "${needle}" "${published_bootstrap}"; then
      echo "[validate.pages][error] published 9.1 bootstrap is stale or missing bootstrap policy marker: ${needle}"
      rc=1
    fi
  done

  if [[ ! -f "${published_common}" ]]; then
    echo "[validate.pages][error] published release.common.sh was not fetched"
    rc=1
    return
  fi

  for needle in \
    'select.ansible.bootstrap.python()' \
    'ansible.version.line.matches.policy()' \
    'ansible-playbook [core ${ANSIBLE_CORE_VERSION}]' \
    'Using native system Python for Ansible bootstrap' \
    'Installing venv support for system Python' \
    'python${python_mm}-venv'; do
    if ! grep -Fq -- "${needle}" "${published_common}"; then
      echo "[validate.pages][error] published release.common.sh is stale or missing native system Python bootstrap marker: ${needle}"
      rc=1
    fi
  done
  if [[ "$(grep -Fc 'if ansible.venv.matches.policy; then' "${published_common}" || true)" -ne 2 ]]; then
    echo "[validate.pages][error] published managed and container Ansible paths do not share the version-policy predicate"
    rc=1
  fi

  playlist_runner_body="$(sed -n '/^maybe\.run\.ansible() {$/,/^}$/p' "${published_common}")"
  for needle in \
    'ensure.managed.ansible' \
    'ensure.managed.target.python' \
    'fetch.playlist' \
    'run.playlist'; do
    if ! grep -Fq -- "${needle}" <<< "${playlist_runner_body}"; then
      echo "[validate.pages][error] published maybe.run.ansible is missing required call: ${needle}"
      rc=1
    fi
  done

  managed_ansible_line="$(grep -nF 'ensure.managed.ansible' <<< "${playlist_runner_body}" | head -n1 | cut -d: -f1 || true)"
  managed_target_line="$(grep -nF 'ensure.managed.target.python' <<< "${playlist_runner_body}" | head -n1 | cut -d: -f1 || true)"
  fetch_playlist_line="$(grep -nF 'fetch.playlist' <<< "${playlist_runner_body}" | head -n1 | cut -d: -f1 || true)"
  run_playlist_line="$(grep -nF 'run.playlist' <<< "${playlist_runner_body}" | head -n1 | cut -d: -f1 || true)"
  if [[ -z "${managed_ansible_line}" || -z "${managed_target_line}" || -z "${fetch_playlist_line}" || -z "${run_playlist_line}" ]] \
    || (( managed_ansible_line >= managed_target_line )) \
    || (( managed_target_line >= fetch_playlist_line )) \
    || (( fetch_playlist_line >= run_playlist_line )); then
    echo "[validate.pages][error] published maybe.run.ansible bootstrap call order is invalid"
    rc=1
  fi

  if [[ ! -f "${published_enterprise}" ]]; then
    echo "[validate.pages][error] published ansible/release/9.1/enterprise.yml was not fetched"
    rc=1
    return
  fi

  for needle in \
    'Find enterprise deb822/list apt source files for cleanup' \
    'Remove enterprise deb822/list apt source files when using no-subscription' \
    'ceph.release.gpg'; do
    if ! grep -q -- "${needle}" "${published_enterprise}"; then
      echo "[validate.pages][error] published 9.1 enterprise policy is stale or missing cleanup marker: ${needle}"
      rc=1
    fi
  done
}

check_published_users_policy() {
  local published_users="${TMPDIR}/ansible/debian/users.yml"

  if [[ ! -f "${published_users}" ]]; then
    echo "[validate.pages][error] published ansible/debian/users.yml was not fetched"
    rc=1
    return
  fi

  if grep -Fq 'proxmox_users_skip_container_safety_checks: "{{ proxmox_users_skip_container_safety_checks |' "${published_users}"; then
    echo "[validate.pages][error] published users.yml contains a recursive container safety variable"
    rc=1
  fi
  if ! grep -Fq 'proxmox_users_skip_container_safety_checks_effective: "{{ proxmox_users_skip_container_safety_checks | default(false) | bool }}"' "${published_users}"; then
    echo "[validate.pages][error] published users.yml is missing the effective container safety variable"
    rc=1
  fi
  if grep -Eq '^[[:space:]]+when: not proxmox_users_skip_container_safety_checks$' "${published_users}"; then
    echo "[validate.pages][error] published users.yml bypasses the effective container safety variable"
    rc=1
  fi
  if [[ "$(grep -Ec '^[[:space:]]+when: not proxmox_users_skip_container_safety_checks_effective$' "${published_users}" || true)" -ne 9 ]]; then
    echo "[validate.pages][error] published users.yml does not guard all nine host safety tasks"
    rc=1
  fi
}

check_published_debian_lxc_policy() {
  local published_runner="${TMPDIR}/setup/lxc/debian.sh"
  local needle

  if [[ ! -f "${published_runner}" ]]; then
    echo "[validate.pages][error] published setup/lxc/debian.sh was not fetched"
    rc=1
    return
  fi

  for needle in \
    'debian-10-standard_10.7-1_amd64.tar.gz' \
    'debian-11-standard_11.7-1_amd64.tar.zst' \
    'debian-12-standard_12.12-1_amd64.tar.zst' \
    'debian-13-standard_13.1-2_amd64.tar.zst' \
    'DEBIAN_LXC_TEMPLATE_BASE_URL' \
    'official URL fallback' \
    'show Debian ISO + web reference context' \
    'Detected host mountpoint passthrough candidates:' \
    'Select mountpoints: single `4`, range `2-4`, CSV `1,3,4`, `ALL`, or `NONE`' \
    "printf '/media/%s" \
    'Select access mode:' \
    'test access (SSH + default users/passwords)' \
    'Web-based Debian netinst references from ansible/debian/netboot.yml'; do
    if ! grep -q -- "${needle}" "${published_runner}"; then
      echo "[validate.pages][error] published setup/lxc/debian.sh is stale or missing Debian LXC policy marker: ${needle}"
      rc=1
    fi
  done

  if grep -q 'show Debian web references' "${published_runner}"; then
    echo "[validate.pages][error] published setup/lxc/debian.sh still has stale menu label: show Debian web references"
    rc=1
  fi
}

check_published_debian_lxc_playbook_policy() {
  local published_lxc="${TMPDIR}/ansible/proxmox/container/debian.lxc.yml"
  local needle

  if [[ ! -f "${published_lxc}" ]]; then
    echo "[validate.pages][error] published ansible/proxmox/container/debian.lxc.yml was not fetched"
    rc=1
    return
  fi

  for needle in \
    'Mount selected container rootfs for mountpoint preparation' \
    'Resolve mounted container rootfs path as a scalar string' \
    'Assert mounted container rootfs path resolved to scalar string' \
    'Ensure parent directories for selected mountpoint targets exist inside mounted container rootfs' \
    'Assert selected mountpoints were attached to container config' \
    'Assert selected mountpoints are visible inside the running container' \
    'Capture runner-normalized static IPv4 CIDR for pct create' \
    'Append default /24 when static IPv4 selection is a bare address' \
    'Report effective static IPv4 payload before pct create' \
    'Assert effective static IPv4 and gateway syntax before pct create' \
    'Report effective pct net0 string before pct create'; do
    if ! grep -q -- "${needle}" "${published_lxc}"; then
      echo "[validate.pages][error] published debian.lxc.yml is stale or missing mountpoint marker: ${needle}"
      rc=1
    fi
  done

  if grep -q 'Normalize static IPv4 source input for pct create' "${published_lxc}"; then
    echo "[validate.pages][error] published debian.lxc.yml still has the stale static IPv4 regex re-normalization path"
    rc=1
  fi

  if grep -Fq "regex_search(\"'([^']+)'\", '\\1')" "${published_lxc}"; then
    echo "[validate.pages][error] published debian.lxc.yml still has list-prone rootfs capture-group regex path derivation"
    rc=1
  fi
}

check_published_debian_base_bootstrap() {
  local published_base="${TMPDIR}/ansible/proxmox/container/debian.base.yml"
  local needle

  if [[ ! -f "${published_base}" ]]; then
    echo "[validate.pages][error] published ansible/proxmox/container/debian.base.yml was not fetched"
    rc=1
    return
  fi

  for needle in \
    'APT_LISTCHANGES_FRONTEND=none' \
    'TMPDIR=/tmp' \
    'LC_ALL=C.UTF-8' \
    '/tmp/user/0' \
    'Ensure access users exist inside the container' \
    'Capture Debian version details from the container' \
    'Capture default IPv4 route from the container' \
    'Capture container resolver nameservers' \
    'Probe internet IPv4 connectivity from the container' \
    'Load shared Debian SSH defaults' \
    'PasswordAuthentication' \
    'Ensure SSH host keys exist inside the container' \
    'Restart SSH service inside the container' \
    'Capture system Python 3 version from the container' \
    'samba_runner_ready' \
    'python3-venv' \
    'ssh_listener_state' \
    'default_login_pairs' \
    'dpkg' \
    '--configure' \
    "'-f', 'install'"; do
    if ! grep -q -- "${needle}" "${published_base}"; then
      echo "[validate.pages][error] published debian.base.yml is stale or missing apt/dpkg bootstrap marker: ${needle}"
      rc=1
    fi
  done
}

check_published_samba_playbook_policy() {
  local published_samba="${TMPDIR}/ansible/proxmox/container/samba.file.share.yml"
  local needle

  if [[ ! -f "${published_samba}" ]]; then
    echo "[validate.pages][error] published ansible/proxmox/container/samba.file.share.yml was not fetched"
    rc=1
    return
  fi

  for needle in \
    'No Samba shares were selected. Continuing with base Samba setup only.' \
    'share_count:' \
    'Normalize Samba selection payload' \
    'Build effective Samba model' \
    'Report effective Samba share count before smb.conf render' \
    'Assert guest browse lists selected shares when guest mode is enabled' \
    'guest account ='; do
    if ! grep -q -- "${needle}" "${published_samba}"; then
      echo "[validate.pages][error] published samba.file.share.yml is stale or missing no-share marker: ${needle}"
      rc=1
    fi
  done
}

check_published_network_runner_policy() {
  local published_runner="${TMPDIR}/setup/lxc/network.sh"
  local needle

  if [[ ! -f "${published_runner}" ]]; then
    echo "[validate.pages][error] published setup/lxc/network.sh was not fetched"
    rc=1
    return
  fi

  for needle in \
    'ensure.container.ansible' \
    'FEATURE_PLAYBOOKS=' \
    'NETWORK_EXTRA_VARS_PATH' \
    'write.network.extra.vars.file()' \
    'lxc.network.selection.yml' \
    'proxmox_feature_defaults:' \
    '  lxc_network:' \
    'This network feature must run inside a Debian LXC container, not on the Proxmox host.' \
    'run.feature.playbook "${NETWORK_PLAYBOOK_PATH}" -e "@${NETWORK_EXTRA_VARS_PATH}"'; do
    if ! grep -q -- "${needle}" "${published_runner}"; then
      echo "[validate.pages][error] published setup/lxc/network.sh is stale or missing marker: ${needle}"
      rc=1
    fi
  done

  if grep -q 'ensure.managed.ansible' "${published_runner}"; then
    echo "[validate.pages][error] published setup/lxc/network.sh still uses managed-target Ansible bootstrap path"
    rc=1
  fi
}

check_published_network_playbook_policy() {
  local published_playbook="${TMPDIR}/ansible/proxmox/container/network.access.yml"
  local needle

  if [[ ! -f "${published_playbook}" ]]; then
    echo "[validate.pages][error] published ansible/proxmox/container/network.access.yml was not fetched"
    rc=1
    return
  fi

  for needle in \
    'proxmox_lxc_network_defaults_safe:' \
    'Fail if run on a Proxmox host' \
    'Build effective access profile' \
    'Build effective access user allow-lists' \
    'Apply access profile behavior overrides' \
    'Install local-LAN access packages' \
    'proxmox_lxc_network_sudo_users_non_root' \
    'Ensure all detected non-root login-capable users can use sudo' \
    'Write managed SSH policy include' \
    'Probe outbound connectivity in preflight' \
    'Configure UFW local-subnet SSH allow rules' \
    'Enable UFW' \
    'Validate FUSE device for container client tooling' \
    'Persist LXC network runtime facts' \
    'Report apply summary' \
    'Report preflight summary'; do
    if ! grep -q -- "${needle}" "${published_playbook}"; then
      echo "[validate.pages][error] published network.access.yml is stale or missing marker: ${needle}"
      rc=1
    fi
  done
}

if ! is.true "${VALIDATE_PAGES_GRAPH_ONLY}"; then
  check_published_samba_runner_policy
  check_published_release91_bootstrap_policy
  check_published_users_policy
  check_published_debian_lxc_policy
  check_published_debian_lxc_playbook_policy
  check_published_debian_base_bootstrap
  check_published_samba_playbook_policy
  check_published_network_runner_policy
  check_published_network_playbook_policy
  check_generated_file_artifacts
fi

check_published_lxc_network_runner_policy() {
  local published_runner="${TMPDIR}/setup/lxc/network.sh"
  local published_playbook="${TMPDIR}/ansible/proxmox/container/network.access.yml"

  if [[ ! -f "${published_runner}" ]]; then
    echo "[validate.pages][error] published setup/lxc/network.sh was not fetched"
    rc=1
    return
  fi

  for needle in \
    'FEATURE_SFTP_ENABLED' \
    'PROXMOX_LXC_NETWORK_SFTP_ENABLED' \
    'Enable SFTP over SSH' \
    'sftp:' ; do
    if ! grep -q -- "${needle}" "${published_runner}"; then
      echo "[validate.pages][error] published setup/lxc/network.sh is missing marker: ${needle}"
      rc=1
    fi
  done

  if [[ ! -f "${published_playbook}" ]]; then
    local playbook_url="${BASE_URL}/ansible/proxmox/container/network.access.yml"
    echo "[validate.pages] fetch ${playbook_url}"
    if ! curl -fsSL "${playbook_url}" -o "${published_playbook}"; then
      echo "[validate.pages][error] failed to fetch published ansible/proxmox/container/network.access.yml"
      rc=1
      return
    fi
  fi

  for needle in \
    'proxmox_lxc_network_selector_sftp' \
    'proxmox_lxc_network_sftp_enabled' \
    'Ensure managed SFTP subsystem declaration exists' \
    'Detect exact SSH SFTP subsystem declaration' \
    'sshd_config_valid' ; do
    if ! grep -q -- "${needle}" "${published_playbook}"; then
      echo "[validate.pages][error] published network.access.yml is missing marker: ${needle}"
      rc=1
    fi
  done
}

if ! is.true "${VALIDATE_PAGES_GRAPH_ONLY}"; then
  check_published_lxc_network_runner_policy
fi

rm -rf "${TMPDIR}"
exit "${rc}"
