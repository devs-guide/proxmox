#!/usr/bin/env bash
set -euo pipefail

# Simple artifact drift check: fetch published Pages artifacts and diff against working tree.
BASE_URL="${BASE_URL:-https://devs-guide.github.io/proxmox}"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
FILES=(
  "6.4.sh:bootstrap/release.6.4.sh"
  "9.1.sh:bootstrap/release.9.1.sh"
  "release.common.sh:bootstrap/release.common.sh"
  "setup.vlan.sh:setup/vlan.sh"
  "setup/lxc/debian.sh:setup/lxc/debian.sh"
  "setup/lxc/samba.sh:setup/lxc/samba.sh"
  "ansible/proxmox/container/debian.lxc.yml:ansible/proxmox/container/debian.lxc.yml"
  "ansible/proxmox/container/debian.base.yml:ansible/proxmox/container/debian.base.yml"
  "ansible/proxmox/container/samba.file.share.yml:ansible/proxmox/container/samba.file.share.yml"
  "ansible/debian/install.packages.yml:ansible/debian/install.packages.yml"
  "ansible/debian/netboot.yml:ansible/debian/netboot.yml"
  "ansible/debian/packages.yml:ansible/debian/packages.yml"
  "ansible/debian/ssh.yml:ansible/debian/ssh.yml"
  "ansible/debian/sources.trixie.yml:ansible/debian/sources.trixie.yml"
  "ansible/group_vars/proxmox.yml:ansible/group_vars/proxmox.yml"
  "ansible/group_vars/trixie.yml:ansible/group_vars/trixie.yml"
  "ansible/release/9.1/group_vars/all.yml:ansible/release/9.1/group_vars/all.yml"
)

echo "[validate.pages] using BASE_URL=${BASE_URL}"
echo "[validate.pages] temp dir: ${TMPDIR}"

rc=0
for entry in "${FILES[@]}"; do
  remote_path="${entry%%:*}"
  local_path="${entry#*:}"
  dest="${TMPDIR}/${remote_path}"
  mkdir -p "$(dirname "${dest}")"

  url="${BASE_URL}/${remote_path}"
  echo "[validate.pages] fetch ${url}"
  if ! curl -fsSL "${url}" -o "${dest}"; then
    echo "[validate.pages][error] failed to fetch ${url}"
    rc=1
    continue
  fi

  if ! diff -u "${WORKDIR}/${local_path}" "${dest}" >/dev/null; then
    echo "[validate.pages][diff] ${local_path} differs from published ${url}"
    diff -u "${WORKDIR}/${local_path}" "${dest}" || true
    rc=1
  else
    echo "[validate.pages][ok] ${local_path} matches published ${url}"
  fi
done

check_setup_feature_refs() {
  local runner_rel="$1"
  local runner_path="${WORKDIR}/${runner_rel}"
  local feature_ref
  local -a _setup_feature_refs=()

  if [[ ! -f "${runner_path}" ]]; then
    echo "[validate.pages][error] missing local setup runner: ${runner_path}"
    rc=1
    return
  fi

  while IFS= read -r feature_ref; do
    [[ -n "${feature_ref}" ]] || continue
    _setup_feature_refs+=("${feature_ref}")
  done < <(
    sed -n '/^[[:space:]]*FEATURE_PLAYBOOKS=(/,/^[[:space:]]*)/p' "${runner_path}" \
      | grep -Eo '"[^"]+"' \
      | tr -d '"'
  )

  if ((${#_setup_feature_refs[@]} == 0)); then
    echo "[validate.pages][error] ${runner_rel} has empty or missing FEATURE_PLAYBOOKS array"
    rc=1
    return
  fi

  for feature_ref in "${_setup_feature_refs[@]}"; do
    local local_playbook="ansible/${feature_ref}"
    local remote_playbook="ansible/${feature_ref}"
    local tmp_playbook="${TMPDIR}/${remote_playbook}"
    local playbook_url="${BASE_URL}/${remote_playbook}"

    if [[ ! -f "${WORKDIR}/${local_playbook}" ]]; then
      echo "[validate.pages][error] ${runner_rel} references missing local playbook: ${local_playbook}"
      rc=1
      continue
    fi

    mkdir -p "$(dirname "${tmp_playbook}")"
    echo "[validate.pages] fetch ${playbook_url}"
    if ! curl -fsSL "${playbook_url}" -o "${tmp_playbook}"; then
      echo "[validate.pages][error] failed to fetch setup dependency ${playbook_url}"
      rc=1
      continue
    fi

    if ! diff -u "${WORKDIR}/${local_playbook}" "${tmp_playbook}" >/dev/null; then
      echo "[validate.pages][diff] ${local_playbook} differs from published ${playbook_url}"
      diff -u "${WORKDIR}/${local_playbook}" "${tmp_playbook}" || true
      rc=1
    else
      echo "[validate.pages][ok] ${local_playbook} matches published ${playbook_url}"
    fi
  done
}

check_playlist_refs() {
  local playlist_path="$1"
  local remote_playlist="${playlist_path}"
  local tmp_playlist="${TMPDIR}/${remote_playlist}"
  mkdir -p "$(dirname "${tmp_playlist}")"

  local playlist_url="${BASE_URL}/${remote_playlist}"
  echo "[validate.pages] fetch ${playlist_url}"
  if ! curl -fsSL "${playlist_url}" -o "${tmp_playlist}"; then
    echo "[validate.pages][error] failed to fetch ${playlist_url}"
    rc=1
    return
  fi

  if ! diff -u "${WORKDIR}/${playlist_path}" "${tmp_playlist}" >/dev/null; then
    echo "[validate.pages][diff] ${playlist_path} differs from published ${playlist_url}"
    diff -u "${WORKDIR}/${playlist_path}" "${tmp_playlist}" || true
    rc=1
  else
    echo "[validate.pages][ok] ${playlist_path} matches published ${playlist_url}"
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
    mkdir -p "$(dirname "${tmp_playbook}")"
    local playbook_url="${BASE_URL}/${remote_playbook}"
    echo "[validate.pages] fetch ${playbook_url}"
    if ! curl -fsSL "${playbook_url}" -o "${tmp_playbook}"; then
      echo "[validate.pages][error] failed to fetch referenced playbook ${playbook_url}"
      rc=1
      continue
    fi
  done < <(sed 's/[[:space:]]*$//' "${WORKDIR}/${playlist_path}" | grep -vE '^[[:space:]]*(#|$)')
}

check_playlist_refs "ansible/release/6.4/install.playbooks.txt"
check_playlist_refs "ansible/release/9.1/install.playbooks.txt"
check_setup_feature_refs "setup/vlan.sh"
check_setup_feature_refs "setup/lxc/debian.sh"
check_setup_feature_refs "setup/lxc/samba.sh"

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
    'Initialize static IPv4 CIDR fact for DHCP-safe create flow' \
    'Normalize static IPv4 source input for pct create' \
    'Resolve static IPv4 CIDR for pct create' \
    'Assert normalized static IPv4 and gateway syntax before pct create'; do
    if ! grep -q -- "${needle}" "${published_lxc}"; then
      echo "[validate.pages][error] published debian.lxc.yml is stale or missing mountpoint marker: ${needle}"
      rc=1
    fi
  done

  if grep -q 'proxmox_lxc_debian_ipv4_parts:' "${published_lxc}"; then
    echo "[validate.pages][error] published debian.lxc.yml still has same-task static IPv4 intermediate facts"
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
    'Report effective Samba share count before smb.conf render'; do
    if ! grep -q -- "${needle}" "${published_samba}"; then
      echo "[validate.pages][error] published samba.file.share.yml is stale or missing no-share marker: ${needle}"
      rc=1
    fi
  done
}

check_published_samba_runner_policy
check_published_debian_lxc_policy
check_published_debian_lxc_playbook_policy
check_published_debian_base_bootstrap
check_published_samba_playbook_policy

rm -rf "${TMPDIR}"
exit "${rc}"
