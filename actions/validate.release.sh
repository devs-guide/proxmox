#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF="${RELEASE_BASE_REF:-0.0.4}"

fail() {
  printf '[validate.release][error] %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '[validate.release][ok] %s\n' "$*"
}

cd "${ROOT}"

release_policy="docs/release/publication.md"
release_template="docs/release/template.md"

for release_document in "${release_policy}" "${release_template}"; do
  [[ -s "${release_document}" ]] || \
    fail "release publication contract is missing: ${release_document}"
done

for policy_marker in \
  '## Human review gate' \
  '## Required release structure' \
  '## Retroactive release reconciliation' \
  '### Notable commits since <previous-tag>' \
  'A human approved the exact title and body'; do
  grep -Fq -- "${policy_marker}" "${release_policy}" || \
    fail "release publication policy is missing marker: ${policy_marker}"
done

for template_heading in \
  '## X.Y.Z' \
  '### Scope' \
  '### Highlights' \
  '### Added' \
  '### Changed' \
  '### Fixed' \
  '### #COMMIT' \
  '### Notable commits since <previous-tag>' \
  '### Assets'; do
  grep -Fq -- "${template_heading}" "${release_template}" || \
    fail "release body template is missing heading: ${template_heading}"
done
ok "release publication policy and human-review template are present"

git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null || \
  fail "release base is unavailable: ${BASE_REF}"

if ! git diff --check "${BASE_REF}..HEAD"; then
  fail "candidate range contains whitespace errors: ${BASE_REF}..HEAD"
fi
ok "candidate range has no whitespace errors"

shell_files=()
while IFS= read -r -d '' path; do
  shell_files+=("${path}")
  bash -n "${path}" || fail "shell syntax failed: ${path}"
done < <(git ls-files -z '*.sh')
((${#shell_files[@]})) || fail "no tracked shell entrypoints were found"
ok "all tracked shell entrypoints and helpers pass bash syntax validation"

empty_tracked=()
while IFS= read -r -d '' path; do
  if [[ ! -s "${path}" ]]; then
    empty_tracked+=("${path}")
  fi
done < <(git ls-files -z)
if ((${#empty_tracked[@]})); then
  printf '[validate.release][error] tracked zero-byte file: %s\n' "${empty_tracked[@]}" >&2
  exit 1
fi
ok "tracked source contains no zero-byte placeholders"

generated_changes=()
while IFS= read -r -d '' path; do
  case "${path}" in
    static/*|www/*|log/*|logs/*) generated_changes+=("${path}") ;;
  esac
done < <(git diff --name-only -z "${BASE_REF}..HEAD")
if ((${#generated_changes[@]})); then
  printf '[validate.release][error] generated/publication output changed in the release range: %s\n' \
    "${generated_changes[@]}" >&2
  exit 1
fi
ok "candidate range contains no generated/publication output"

private_paths=()
while IFS= read -r -d '' path; do
  normalized="${path,,}"
  case "${normalized}" in
    *.pem|*.p12|*.pfx|*.key|*/id_rsa|*/id_dsa|*/id_ecdsa|*/id_ed25519)
      private_paths+=("${path}")
      ;;
  esac
done < <(git ls-files -z)
if ((${#private_paths[@]})); then
  printf '[validate.release][error] tracked private-key-like path: %s\n' "${private_paths[@]}" >&2
  exit 1
fi

private_material=""
if private_material="$(
  git grep -nI -E \
    -e '-----BEGIN (OPENSSH|RSA|DSA|EC|PGP) PRIVATE KEY-----' \
    -e '(^|[^[:alnum:]_])gh[pousr]_[[:alnum:]]{36,}([^[:alnum:]_]|$)' \
    -e '(^|[^[:alnum:]_])AKIA[0-9A-Z]{16}([^[:alnum:]_]|$)' \
    -- .
)"; then
  printf '%s\n' "${private_material}" >&2
  fail "tracked source contains private credential material"
else
  grep_status="$?"
  [[ "${grep_status}" == "1" ]] || fail "credential scan failed with exit ${grep_status}"
fi
ok "tracked source contains no private-key files or recognized credential material"

branding_hits="$(
  grep -RInEi --exclude-dir='.git' -- '(devs-guide|devsguide)' \
    bootstrap setup cli ansible || true
)"
branding_violations=()
while IFS= read -r hit; do
  [[ -n "${hit}" ]] || continue
  path="${hit%%:*}"
  remainder="${hit#*:}"
  line_number="${remainder%%:*}"
  content="${remainder#*:}"

  sanitized="${content//https:\/\/devs-guide.github.io\/proxmox/https:\/\/<public-pages-host>\/proxmox}"
  if [[ "${path}" == "ansible/config.github.yml" || "${path}" == "ansible/group_vars/all.yml" ]]; then
    sanitized="${sanitized//repo_owner: \"devs-guide\"/repo_owner: \"<public-repository-owner>\"}"
  fi
  if [[ "${path}" == "bootstrap/metal.sh" \
    && "${content}" == "GITHUB[user]='devs-guide'" ]]; then
    sanitized=""
  fi
  if [[ "${path}" == "ansible/proxmox/tasks/data-link.candidate.yml" \
    && "${content}" == *'devsguide-proxmox-vlan-vmbr1'* ]]; then
    sanitized=""
  fi

  if [[ "${sanitized,,}" == *devs-guide* || "${sanitized,,}" == *devsguide* ]]; then
    branding_violations+=("${path}:${line_number}:${content}")
  fi
done <<< "${branding_hits}"

if ((${#branding_violations[@]})); then
  printf '[validate.release][error] repository branding is not allowed in generated host state: %s\n' \
    "${branding_violations[@]}" >&2
  exit 1
fi

legacy_marker_count="$(
  grep -Fc -- 'devsguide-proxmox-vlan-vmbr1' ansible/proxmox/tasks/data-link.candidate.yml || true
)"
[[ "${legacy_marker_count}" == "1" ]] || \
  fail "the reviewed legacy VLAN marker must appear exactly once"
grep -Fq 'function owned(name)' ansible/proxmox/tasks/data-link.candidate.yml || \
  fail "the reviewed legacy VLAN marker must remain in canonical feature-owned detection"
ok "host-state branding is limited to public provenance and reviewed legacy detection"

printf '[validate.release] all release hygiene contracts passed\n'
