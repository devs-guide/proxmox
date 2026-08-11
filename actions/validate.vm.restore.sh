#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${ROOT}/setup/vm/restore.sh"
COMMON="${ROOT}/cli/lib/restore.common.sh"
SSH_SYNC="${ROOT}/cli/ssh/sync.sh"
STORAGE_TEMP="${ROOT}/cli/storage/temp.sh"
RSYNC_FETCH="${ROOT}/cli/rsync/fetch.sh"
PLAYBOOK="${ROOT}/ansible/proxmox/helper/vm.restore.yml"

fail() {
  printf '[validate.vm.restore][error] %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '[validate.vm.restore][ok] %s\n' "$*"
}

expect_exit() {
  local expected="$1"
  shift
  local actual=0
  set +e
  "$@" >/dev/null 2>/dev/null
  actual=$?
  set -e
  [[ "${actual}" == "${expected}" ]] || fail "expected exit ${expected}, got ${actual}: $*"
}

for path in "${RUNNER}" "${COMMON}" "${SSH_SYNC}" "${STORAGE_TEMP}" "${RSYNC_FETCH}" "${PLAYBOOK}"; do
  [[ -f "${path}" ]] || fail "required implementation file is missing: ${path#${ROOT}/}"
done
for path in "${RUNNER}" "${SSH_SYNC}" "${STORAGE_TEMP}" "${RSYNC_FETCH}"; do
  [[ -x "${path}" ]] || fail "command is not executable: ${path#${ROOT}/}"
done

bash -n "${RUNNER}" "${COMMON}" "${SSH_SYNC}" "${STORAGE_TEMP}" "${RSYNC_FETCH}"
ok "all restore shell artifacts pass bash -n"

for command_path in "${RUNNER}" "${SSH_SYNC}" "${STORAGE_TEMP}" "${RSYNC_FETCH}"; do
  help_output="$("${command_path}" --help)"
  grep -q -- '--help' <<<"${help_output}" || fail "help output missing --help: ${command_path#${ROOT}/}"
  grep -q -- '--dry-run' <<<"${help_output}" || fail "help output missing --dry-run: ${command_path#${ROOT}/}"
done
for required_flag in --key-rotation --yes; do
  grep -q -- "${required_flag}" <<<"$("${SSH_SYNC}" --help)" || fail "SSH helper help missing ${required_flag}"
done
for required_flag in --vm --action --stage-storage --target-storage --replace-existing --unique --cleanup --output; do
  grep -q -- "${required_flag}" <<<"$("${RUNNER}" --help)" || fail "runner help missing ${required_flag}"
done
ok "help and named-flag contracts are present"

stream_tmp="$(mktemp -d)"
for command_path in "${SSH_SYNC}" "${STORAGE_TEMP}" "${RSYNC_FETCH}"; do
  stream_help="$(
    PROXMOX_RESTORE_PAGES_BASE_URL="file://${ROOT}" \
    PROXMOX_RESTORE_TMP_DIR="${stream_tmp}" \
      bash -s -- --help < "${command_path}"
  )"
  grep -q -- '--help' <<<"${stream_help}" || fail "streamed helper bootstrap failed: ${command_path#${ROOT}/}"
done
stream_setup="$(
  PROXMOX_RESTORE_PAGES_BASE_URL="file://${ROOT}" \
  PROXMOX_RESTORE_TMP_DIR="${stream_tmp}" \
    bash -s -- \
      --action setup \
      --remote-host 192.0.2.1 \
      --identity "${stream_tmp}/identity" \
      --known-hosts "${stream_tmp}/known_hosts" \
      --key-rotation \
      --yes \
      --dry-run < "${SSH_SYNC}" 2>&1
)"
grep -q 'ssh-copy-id' <<<"${stream_setup}" || fail "streamed SSH setup dry-run did not render ssh-copy-id"
grep -q 'atomically replace' <<<"${stream_setup}" || fail "streamed SSH key-rotation dry-run did not render replacement plan"
rm -rf "${stream_tmp}"
ok "published helper entrypoints bootstrap restore.common.sh when streamed"

if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3))); then
  rotation_tmp="$(mktemp -d)"
  rotation_bin="${rotation_tmp}/bin"
  rotation_remote="${rotation_tmp}/remote"
  rotation_identity="${rotation_tmp}/proxmox-restore-ed25519"
  rotation_known_hosts="${rotation_tmp}/known_hosts"
  mkdir -p "${rotation_bin}" "${rotation_remote}/.ssh"
  printf 'OLD_PRIVATE\n' >"${rotation_identity}"
  printf 'ssh-ed25519 U1RBTEVfUFVCTElDX0tFWQ== stale-public\n' >"${rotation_identity}.pub"
  printf 'mock-known-host\n' >"${rotation_known_hosts}"
  cat >"${rotation_remote}/.ssh/authorized_keys" <<'EOF'
from="10.0.0.0/8" ssh-ed25519 T0xEX1BSSVZBVEVfS0VZ old-private
ssh-ed25519 U1RBTEVfUFVCTElDX0tFWQ== stale-public
ssh-ed25519 VU5SRUxBVEVEX0tFWQ== unrelated
EOF
  cat >"${rotation_bin}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="generate"
identity=""
while (($#)); do
  case "$1" in
    -y) mode="derive"; shift ;;
    -f) identity="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "${identity}" ]] || exit 2
if [[ "${mode}" == derive ]]; then
  if grep -Fxq 'NEW_PRIVATE' "${identity}"; then
    printf 'ssh-ed25519 TkVXX1BVQkxJQ19LRVk=\n'
  else
    printf 'ssh-ed25519 T0xEX1BSSVZBVEVfS0VZ\n'
  fi
else
  printf 'NEW_PRIVATE\n' >"${identity}"
  printf 'ssh-ed25519 TkVXX1BVQkxJQ19LRVk= rotated\n' >"${identity}.pub"
fi
EOF
  cat >"${rotation_bin}/ssh-copy-id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
public_key=""
while (($#)); do
  case "$1" in
    -i) public_key="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -f "${public_key}" ]]
[[ "${MOCK_SSH_COPY_ID_FAIL:-0}" != 1 ]] || exit 1
cat "${public_key}" >>"${MOCK_REMOTE_AUTHORIZED_KEYS}"
EOF
  cat >"${rotation_bin}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
  if [[ "$1" == bash ]]; then
    shift
    PROXMOX_RESTORE_AUTHORIZED_KEYS="${MOCK_REMOTE_AUTHORIZED_KEYS}" /bin/bash "$@"
    exit $?
  fi
  shift
done
exit 0
EOF
  chmod 0755 "${rotation_bin}/ssh-keygen" "${rotation_bin}/ssh-copy-id" "${rotation_bin}/ssh"

  set +e
  PATH="${rotation_bin}:${PATH}" \
  MOCK_REMOTE_AUTHORIZED_KEYS="${rotation_remote}/.ssh/authorized_keys" \
  MOCK_SSH_COPY_ID_FAIL=1 \
    "${SSH_SYNC}" \
      --action setup \
      --remote-host 192.0.2.1 \
      --identity "${rotation_identity}" \
      --known-hosts "${rotation_known_hosts}" \
      --key-rotation \
      --yes >/dev/null 2>"${rotation_tmp}/failed-rotation.log"
  failed_rotation_rc=$?
  set -e
  [[ "${failed_rotation_rc}" == "${RESTORE_EXIT_SSH:-20}" ]] || fail "failed key installation returned ${failed_rotation_rc}, expected 20"
  grep -Fxq 'OLD_PRIVATE' "${rotation_identity}" || fail "failed key installation changed the old private key"
  grep -q 'U1RBTEVfUFVCTElDX0tFWQ==' "${rotation_identity}.pub" || fail "failed key installation changed the old public key"

  PATH="${rotation_bin}:${PATH}" \
  MOCK_REMOTE_AUTHORIZED_KEYS="${rotation_remote}/.ssh/authorized_keys" \
    "${SSH_SYNC}" \
      --action setup \
      --remote-host 192.0.2.1 \
      --identity "${rotation_identity}" \
      --known-hosts "${rotation_known_hosts}" \
      --key-rotation \
      --yes >/dev/null 2>"${rotation_tmp}/rotation.log"

  grep -Fxq 'NEW_PRIVATE' "${rotation_identity}" || fail "key rotation did not install the fresh private key"
  grep -q 'TkVXX1BVQkxJQ19LRVk=' "${rotation_identity}.pub" || fail "key rotation did not install the fresh public key"
  grep -q 'TkVXX1BVQkxJQ19LRVk=' "${rotation_remote}/.ssh/authorized_keys" || fail "key rotation did not install the fresh remote key"
  grep -q 'VU5SRUxBVEVEX0tFWQ==' "${rotation_remote}/.ssh/authorized_keys" || fail "key rotation removed an unrelated remote key"
  if grep -Eq 'T0xEX1BSSVZBVEVfS0VZ|U1RBTEVfUFVCTElDX0tFWQ==' "${rotation_remote}/.ssh/authorized_keys"; then
    fail "key rotation retained old remote key material"
  fi
  if compgen -G "${rotation_identity}.rotation-old.*" >/dev/null || compgen -G "${rotation_identity}.pub.rotation-old.*" >/dev/null; then
    fail "key rotation retained old local key material after success"
  fi
  grep -q 'key rotation completed' "${rotation_tmp}/rotation.log" || fail "key rotation did not report successful cleanup"
  rm -rf "${rotation_tmp}"
  ok "key rotation replaces a mismatched pair and removes only exact old remote keys"
else
  ok "key rotation integration is deferred to GitHub Actions on Bash 4.3+"
fi

expect_exit 2 "${RUNNER}" --unknown
expect_exit 2 "${RUNNER}" --action cleanup
expect_exit 2 "${SSH_SYNC}" --unknown
expect_exit 2 "${SSH_SYNC}" --action setup --remote-host 192.0.2.1 --key-rotation
expect_exit 2 "${SSH_SYNC}" --action check --remote-host 192.0.2.1 --key-rotation --yes
expect_exit 2 "${SSH_SYNC}" --action setup --remote-host 192.0.2.1 --yes
expect_exit 2 "${STORAGE_TEMP}" --unknown
expect_exit 2 "${RSYNC_FETCH}" --unknown
expect_exit 2 "${RUNNER}" positional
ok "unknown, positional, and missing required arguments return usage exit 2"

derived="$(bash -u -c '
  source "$1"
  RESTORE_LOCK_ROOT=/run/lock
  printf "%s\n" "$(restore.stage_lv_name 321)"
  printf "%s\n" "$(restore.stage_mountpoint /mnt/pve-restore 321)"
  printf "%s\n" "$(restore.vm_lock_path 321)"
' _ "${COMMON}")"
expected=$'restore_stage_vm321\n/mnt/pve-restore/321\n/run/lock/proxmox-restore-vm-321.lock'
[[ "${derived}" == "${expected}" ]] || fail "VM 321 derivation contract failed"
ok "VM ID drives the stage LV, mountpoint, and lock path"

common_values="$(bash -u -c '
  source "$1"
  printf "%s\n" "$(restore.parse_size_bytes 08)"
  printf "%s\n" "$(restore.parse_size_bytes 2GiB)"
  printf "%s\n" "$(restore.auto_stage_bytes 1073741824)"
' _ "${COMMON}")"
[[ "${common_values}" == $'8\n2147483648\n2147483648' ]] || fail "size parser or automatic staging overhead contract failed"
quoted_roundtrip="$(bash -u -c '
  source "$1"
  input="/backup/a'"'"'b c.vma.zst"
  quoted=$(restore.shell_quote "$input")
  command="value=${quoted}; printf \"%s\" \"\$value\""
  bash -c "$command"
' _ "${COMMON}")"
[[ "${quoted_roundtrip}" == "/backup/a'b c.vma.zst" ]] || fail "shell quoting round trip failed"
ok "size calculations and remote-path shell quoting are deterministic"

grep -q 'qmrestore "${ARCHIVE}" "${VM_ID}" --storage "${TARGET_STORAGE}"' "${RUNNER}" || \
  fail "qmrestore does not derive target VM and storage from parsed flags"
if grep -Eq 'qmrestore[^#]*[[:space:]]200([[:space:]]|$)' "${RUNNER}"; then
  fail "runner contains a functional qmrestore target of 200"
fi
grep -q '((RESTORE_REPLACEMENT)) && command+=(--force 1)' "${RUNNER}" || fail "replacement does not gate --force 1"
grep -q '((UNIQUE)) && command+=(--unique 1)' "${RUNNER}" || fail "--unique propagation is missing"
ok "qmrestore target, storage, force, and unique propagation are flag-derived"

for required_rsync_flag in --archive --partial --append-verify --secluded-args --info=progress2; do
  grep -q -- "${required_rsync_flag}" "${RSYNC_FETCH}" || fail "rsync transfer missing ${required_rsync_flag}"
done
if grep -q -- '--compress' "${RSYNC_FETCH}"; then
  fail "rsync transfer enables forbidden network compression"
fi
ok "rsync is resumable, protected, and uncompressed"

if grep -R -q -- '/dev/pve/data' "${ROOT}/cli" "${RUNNER}"; then
  fail "restore runtime hard-codes /dev/pve/data"
fi
if grep -n 'mkfs.ext4' "${STORAGE_TEMP}" | grep -Eq 'THIN_POOL|/data|_tdata|_tmeta'; then
  fail "mkfs call can target a thin pool or protected component"
fi
grep -q 'storage.cfg' "${STORAGE_TEMP}" || fail "stage storage is not resolved from Proxmox configuration"
grep -q 'validate_manifest' "${STORAGE_TEMP}" || fail "stage cleanup lacks manifest validation"
grep -q 'nodev,nosuid,noexec' "${STORAGE_TEMP}" || fail "stage mount options are incomplete"
ok "temporary-storage safety boundary is present"

grep -q 'zstd --no-progress --decompress --stdout' "${RUNNER}" || fail "zstd stream verification is missing"
grep -q 'vma verify -v /dev/stdin' "${RUNNER}" || fail "VMA stream verification is missing"
grep -q 'SHA-256 mismatch' "${RSYNC_FETCH}" || fail "remote/local checksum gate is missing"
grep -q 'check_restore_capacity' "${RUNNER}" || fail "restore capacity gate is missing"
grep -q 'check_vm_collision' "${RUNNER}" || fail "VM collision gate is missing"
ok "integrity, capacity, and collision gates precede restore"

cleanup_line="$(grep -n 'cleanup_stage_if_owned' "${RUNNER}" | tail -n1 | cut -d: -f1)"
start_line="$(grep -n 'start_vm_if_requested' "${RUNNER}" | tail -n1 | cut -d: -f1)"
[[ -n "${cleanup_line}" && -n "${start_line}" && "${cleanup_line}" -lt "${start_line}" ]] || \
  fail "all workflow does not order cleanup before start"
grep -q 'archive and staging LV were retained' "${RUNNER}" || fail "restore failure retention contract is missing"
ok "restore failure retention and cleanup-before-start ordering are explicit"

grep -q 'FEATURE_PLAYBOOKS=(' "${RUNNER}" || fail "runner does not declare playbook dependencies"
grep -q 'FEATURE_CLI_FILES=(' "${RUNNER}" || fail "runner does not declare CLI dependencies"
for cli_ref in lib/restore.common.sh ssh/sync.sh storage/temp.sh rsync/fetch.sh; do
  grep -q "\"${cli_ref}\"" "${RUNNER}" || fail "runner is missing .sh CLI dependency: ${cli_ref}"
done
if grep -Eq '"(lib/restore\.common|ssh/sync|storage/temp|rsync/fetch)"' "${RUNNER}"; then
  fail "runner retains an extensionless CLI dependency"
fi
grep -q 'SETUP_VM_RESTORE_RUNNER="setup/vm/restore.sh"' "${ROOT}/actions/www.pages.sh" || fail "Pages publisher lacks VM restore runner"
grep -q 'setup/vm/restore.sh:setup/vm/restore.sh' "${ROOT}/actions/validate.pages.sh" || fail "Pages validator lacks canonical runner"
grep -q "'cli/\*\*'" "${ROOT}/.github/workflows/www.pages.yml" || fail "Pages workflow does not trigger on cli/**"
grep -q "'setup/vm/\*\*'" "${ROOT}/.github/workflows/www.pages.yml" || fail "Pages workflow does not explicitly trigger on setup/vm/**"
ok "runner, helper, playbook, validation, and workflow publishing are wired"

if grep -q 'ansible.builtin.shell' "${PLAYBOOK}"; then
  fail "dependency playbook contains shell mutation logic"
fi
grep -q 'ansible.builtin.apt' "${PLAYBOOK}" || fail "dependency playbook does not install packages"
for package in rsync openssh-client lvm2 e2fsprogs zstd; do
  grep -q -- "- ${package}" "${PLAYBOOK}" || fail "dependency playbook missing ${package}"
done
ok "Ansible playbook remains dependency-only"

printf '[validate.vm.restore] all contracts passed\n'
