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
    'official URL fallback'; do
    if ! grep -q "${needle}" "${published_runner}"; then
      echo "[validate.pages][error] published setup/lxc/debian.sh is stale or missing Debian LXC policy marker: ${needle}"
      rc=1
    fi
  done
}

check_published_debian_lxc_policy

rm -rf "${TMPDIR}"
exit "${rc}"
