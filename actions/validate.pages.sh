#!/usr/bin/env bash
set -euo pipefail

# Simple artifact drift check: fetch published Pages artifacts and diff against working tree.
BASE_URL="${BASE_URL:-https://devs-guide.github.io/proxmox}"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
FILES=(
  "9.1.sh:bootstrap/release.9.1.sh"
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

rm -rf "${TMPDIR}"
exit "${rc}"
