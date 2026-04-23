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
  "ansible/debian/install.packages.yml:ansible/debian/install.packages.yml"
  "ansible/debian/packages.yml:ansible/debian/packages.yml"
  "ansible/debian/sources.trixie.yml:ansible/debian/sources.trixie.yml"
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
    if [[ ! "${playbook_ref}" == debian/* ]]; then
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

rm -rf "${TMPDIR}"
exit "${rc}"
