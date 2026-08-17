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
command -v jq >/dev/null 2>&1 || fail "jq is required for restore JSON contract validation"

bash -n "${RUNNER}" "${COMMON}" "${SSH_SYNC}" "${STORAGE_TEMP}" "${RSYNC_FETCH}"
ok "all restore shell artifacts pass bash -n"

for command_path in "${RUNNER}" "${SSH_SYNC}" "${STORAGE_TEMP}" "${RSYNC_FETCH}"; do
  help_output="$("${command_path}" --help)"
  grep -q -- '--help' <<<"${help_output}" || fail "help output missing --help: ${command_path#${ROOT}/}"
  grep -q -- '--dry-run' <<<"${help_output}" || fail "help output missing --dry-run: ${command_path#${ROOT}/}"
  grep -q -- 'json' <<<"${help_output}" || fail "help output missing JSON output: ${command_path#${ROOT}/}"
  if grep -q -- 'tsv' <<<"${help_output}"; then
    fail "help output retains the removed TSV interface: ${command_path#${ROOT}/}"
  fi
done
for required_flag in --key-rotation --yes; do
  grep -q -- "${required_flag}" <<<"$("${SSH_SYNC}" --help)" || fail "SSH helper help missing ${required_flag}"
done
for required_flag in --vm --action --remote --local --remote-path --archive-path --stage-storage --target-storage --reset-incomplete-stage --replace-existing --unique --cleanup --output; do
  grep -q -- "${required_flag}" <<<"$("${RUNNER}" --help)" || fail "runner help missing ${required_flag}"
done
grep -q -- '--reset-incomplete-stage' <<<"$("${STORAGE_TEMP}" --help)" || \
  fail "storage helper help missing --reset-incomplete-stage"
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
stream_runner_help="$(
  PROXMOX_RESTORE_PAGES_BASE_URL="file://${ROOT}" \
  PROXMOX_RESTORE_TMP_DIR="${stream_tmp}" \
    bash -s -- --help < "${RUNNER}"
)"
grep -q -- '--action preflight|transfer|verify|restore|cleanup|all' <<<"${stream_runner_help}" || \
  fail "streamed setup/vm/restore.sh did not bootstrap and render help"
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
  storage_args_definition="$(awk '
    /^storage_args\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${RUNNER}")"
  [[ -n "${storage_args_definition}" ]] || fail "could not extract storage_args for regression coverage"
  if ! storage_args_output="$(bash -c '
    set -euo pipefail
    eval "$1"
    VM_ID=100
    STAGE_STORAGE=local-lvm
    MOUNT_ROOT=/mnt/pve-restore
    MAX_THIN_DATA_PERCENT=85
    MAX_THIN_METADATA_PERCENT=75
    SOURCE_VM_ID=200

    DRY_RUN=0
    real_args=()
    storage_args real_args
    printf "real:%s\n" "${real_args[*]}"

    DRY_RUN=1
    dry_args=()
    storage_args dry_args
    printf "dry:%s\n" "${dry_args[*]}"
  ' _ "${storage_args_definition}")"; then
    fail "storage_args returned nonzero under set -e"
  fi
  expected_storage_args=$'real:--vm 100 --storage local-lvm --mount-root /mnt/pve-restore --max-thin-data-percent 85 --max-thin-metadata-percent 75 --source-vm 200\ndry:--vm 100 --storage local-lvm --mount-root /mnt/pve-restore --max-thin-data-percent 85 --max-thin-metadata-percent 75 --source-vm 200 --dry-run'
  [[ "${storage_args_output}" == "${expected_storage_args}" ]] || \
    fail "storage_args regression output did not match the real/dry-run contract"

  dry_run_definition="$(awk '
    /^dry_run_post_transfer\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${RUNNER}")"
  [[ -n "${dry_run_definition}" ]] || fail "could not extract dry_run_post_transfer for regression coverage"
  if ! bash -c '
    set -euo pipefail
    eval "$1"
    restore.log() { :; }
    restore.render_command() { :; }
    check_vm_collision() { RESTORE_REPLACEMENT=0; }
    ARCHIVE=/mnt/pve-restore/100/vzdump-qemu-200-test.vma.zst
    VM_ID=100
    TARGET_STORAGE=local-lvm
    STAGE_STORAGE=local-lvm
    MOUNT_ROOT=/mnt/pve-restore
    STORAGE_TEMP=/tmp/storage-temp.sh
    RESTORE_REPLACEMENT=0
    UNIQUE=1
    RESTORE_BWLIMIT_KBPS=""
    CLEANUP_POLICY=success
    START_VM=0
    CURRENT_PHASE=test
    dry_run_post_transfer
  ' _ "${dry_run_definition}"; then
    fail "dry_run_post_transfer returned nonzero when --start was absent"
  fi
  ok "real-mode argument builders and optional dry-run actions remain successful under set -e"
else
  ok "argument-builder regression is deferred to GitHub Actions on Bash 4.3+"
fi

if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3))); then
  stage_tmp="$(mktemp -d)"
  stage_child="${stage_tmp}/check-child-fd"
  cat >"${stage_child}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ! -e "/proc/self/fd/$1" ]]
printf 'child-closed\n'
EOF
  chmod 0755 "${stage_child}"
  child_fd_output="$(bash -c '
    set -euo pipefail
    source "$1"
    exec {RESTORE_LOCK_FD}>"$2"
    restore.child "$3" "${RESTORE_LOCK_FD}"
    [[ -e "/proc/$$/fd/${RESTORE_LOCK_FD}" ]]
    printf "parent-open\n"
  ' _ "${COMMON}" "${stage_tmp}/lock" "${stage_child}")"
  [[ "${child_fd_output}" == $'child-closed\nparent-open' ]] || \
    fail "restore.child did not isolate the lock descriptor while preserving the parent lock"

  probe_definition="$(awk '
    /^probe_stage_filesystem\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${STORAGE_TEMP}")"
  validate_filesystem_definition="$(awk '
    /^validate_stage_filesystem\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${STORAGE_TEMP}")"
  [[ -n "${probe_definition}" && -n "${validate_filesystem_definition}" ]] || \
    fail "could not extract authoritative filesystem probing functions"
  probe_output="$(bash -c '
    set -euo pipefail
    source "$1"
    eval "$2"
    eval "$3"
    blkid() {
      printf "%s\n" \
        "DEVNAME=/dev/pve/restore_stage_vm100" \
        "UUID=11111111-2222-3333-4444-555555555555" \
        "TYPE=ext4" \
        "LABEL=prxvm100"
    }
    DEVICE=/dev/pve/restore_stage_vm100
    FS_LABEL=prxvm100
    FS_TYPE=""
    FS_PROBE_LABEL=""
    FS_UUID=""
    validate_stage_filesystem
    printf "%s|%s|%s\n" "${FS_TYPE}" "${FS_PROBE_LABEL}" "${FS_UUID}"
  ' _ "${COMMON}" "${probe_definition}" "${validate_filesystem_definition}")"
  [[ "${probe_output}" == 'ext4|prxvm100|11111111-2222-3333-4444-555555555555' ]] || \
    fail "blkid probing did not validate the expected ext4 type, label, and UUID"

  reset_definition="$(awk '
    /^reset_incomplete_stage\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${STORAGE_TEMP}")"
  [[ -n "${reset_definition}" ]] || fail "could not extract guarded incomplete-stage reset"
  for reset_mode in success wrong_size wrong_pool mounted nonempty unknown_label unexpected_tags manifest; do
    reset_marker="${stage_tmp}/reset-${reset_mode}"
    set +e
    RESET_MODE="${reset_mode}" RESET_MARKER="${reset_marker}" bash -c '
      set -euo pipefail
      source "$1"
      eval "$2"
      validate_stage_lv() {
        ACTUAL_STAGE_BYTES=4096
        LV_TAGS=""
        [[ "${RESET_MODE}" != wrong_size ]] || ACTUAL_STAGE_BYTES=8192
        [[ "${RESET_MODE}" != wrong_pool ]] || restore.die "${RESTORE_EXIT_STORAGE}" "wrong thin pool"
        [[ "${RESET_MODE}" != unexpected_tags ]] || LV_TAGS=unrelated
      }
      findmnt() {
        [[ "${RESET_MODE}" != mounted ]] || printf "/mnt/pve-restore/100\n"
      }
      probe_stage_filesystem() {
        FS_TYPE=ext4
        FS_PROBE_LABEL=pve_restore_vm10
        FS_UUID=11111111-2222-3333-4444-555555555555
        [[ "${RESET_MODE}" != unknown_label ]] || FS_PROBE_LABEL=unrelated
      }
      lv_has_tag() { return 1; }
      inspect_device_manifest() {
        DEVICE_MANIFEST_PRESENT=0
        [[ "${RESET_MODE}" != manifest ]] || DEVICE_MANIFEST_PRESENT=1
      }
      restore.confirm_exact() { :; }
      lvremove() { printf "removed\n" >"${RESET_MARKER}"; }
      udevadm() { :; }
      stage_exists() { return 1; }
      read_pool_status() { :; }
      VM_ID=100
      VG_NAME=pve
      THIN_POOL=data
      LV_NAME=restore_stage_vm100
      DEVICE=/dev/pve/restore_stage_vm100
      MOUNTPOINT="$3/mount-${RESET_MODE}"
      mkdir -p "${MOUNTPOINT}"
      [[ "${RESET_MODE}" != nonempty ]] || printf "unrelated\n" >"${MOUNTPOINT}/unrelated"
      MANIFEST="${MOUNTPOINT}/.proxmox-restore.tsv"
      STAGE_BYTES=4096
      LV_OWNER_TAG=pve_restore_stage
      LV_VM_TAG=pve_restore_vm_100
      LEGACY_FS_LABEL=pve_restore_vm10
      FS_LABEL=prxvm100
      DRY_RUN=0
      RESET_COMPLETED=0
      reset_incomplete_stage
      [[ "${RESET_COMPLETED}" == 1 ]]
    ' _ "${COMMON}" "${reset_definition}" "${stage_tmp}" \
      >"${stage_tmp}/reset-${reset_mode}.out" 2>"${stage_tmp}/reset-${reset_mode}.log"
    reset_rc=$?
    set -e
    if [[ "${reset_mode}" == success ]]; then
      [[ "${reset_rc}" == 0 && -f "${reset_marker}" ]] || \
        fail "guarded legacy-stage reset did not complete"
    else
      [[ "${reset_rc}" == 30 && ! -e "${reset_marker}" ]] || \
        fail "guarded reset mode ${reset_mode} did not refuse safely"
    fi
  done

  rollback_definition="$(awk '
    /^rollback_new_stage\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${STORAGE_TEMP}")"
  [[ -n "${rollback_definition}" ]] || fail "could not extract incomplete-stage rollback"
  set +e
  ROLLBACK_LOG="${stage_tmp}/rollback.log" bash -c '
    set -euo pipefail
    source "$1"
    eval "$2"
    umount() { printf "umount\n" >>"${ROLLBACK_LOG}"; }
    lvremove() { printf "lvremove\n" >>"${ROLLBACK_LOG}"; }
    udevadm() { printf "udevadm\n" >>"${ROLLBACK_LOG}"; }
    rmdir() { printf "rmdir\n" >>"${ROLLBACK_LOG}"; }
    stage_exists() { return 1; }
    CREATED_THIS_RUN=1
    MANIFEST_COMMITTED=0
    MOUNTED_THIS_RUN=1
    MOUNTPOINT=/mnt/pve-restore/100
    VG_NAME=pve
    LV_NAME=restore_stage_vm100
    trap rollback_new_stage EXIT
    exit 30
  ' _ "${COMMON}" "${rollback_definition}" >/dev/null 2>"${stage_tmp}/rollback.stderr"
  rollback_rc=$?
  set -e
  [[ "${rollback_rc}" == 30 ]] || fail "transactional rollback changed the original failure status"
  [[ "$(sort "${stage_tmp}/rollback.log")" == $'lvremove\nrmdir\nudevadm\numount' ]] || \
    fail "transactional rollback did not unmount, remove, settle, and clean the stage directory"
  set +e
  ROLLBACK_LOG="${stage_tmp}/committed-rollback.log" bash -c '
    set -euo pipefail
    source "$1"
    eval "$2"
    lvremove() { printf "unexpected-removal\n" >>"${ROLLBACK_LOG}"; }
    stage_exists() { return 0; }
    CREATED_THIS_RUN=1
    MANIFEST_COMMITTED=1
    MOUNTED_THIS_RUN=1
    MOUNTPOINT=/mnt/pve-restore/100
    VG_NAME=pve
    LV_NAME=restore_stage_vm100
    trap rollback_new_stage EXIT
    exit 40
  ' _ "${COMMON}" "${rollback_definition}" >/dev/null 2>"${stage_tmp}/committed-rollback.stderr"
  committed_rc=$?
  set -e
  [[ "${committed_rc}" == 40 && ! -e "${stage_tmp}/committed-rollback.log" ]] || \
    fail "transactional rollback removed a manifest-committed resumable stage"

  grep -q 'FS_LABEL="prxvm${VM_ID}"' "${STORAGE_TEMP}" || fail "storage helper does not use the bounded ext4 label"
  maximum_vm_label="prxvm999999999"
  [[ "${#maximum_vm_label}" -le 16 ]] || fail "maximum accepted VM ID exceeds the ext4 label limit"
  rm -rf "${stage_tmp}"
  ok "stage labels, blkid probing, guarded reset, transactional rollback, and lock-FD isolation are enforced"
else
  ok "staging lifecycle integration is deferred to GitHub Actions on Bash 4.3+"
fi

if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3))); then
  json_tmp="$(mktemp -d)"
  json_bin="${json_tmp}/bin"
  json_identity="${json_tmp}/identity with \"quotes\" and \\backslash"
  json_known_hosts="${json_tmp}/known hosts with \"quotes\" and \\backslash"
  json_basename='vzdump-qemu-200-space "quoted" \backslash.vma.zst'
  json_remote_path="/backup folder/${json_basename}"
  json_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  mkdir -p "${json_bin}"
  printf 'mock-identity\n' >"${json_identity}"
  printf 'mock-known-host\n' >"${json_known_hosts}"
  cat >"${json_bin}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_REMOTE_BYTES:-}" ]]; then
  printf '%s\n%s\n%s\n' "${MOCK_REMOTE_BYTES}" "${MOCK_REMOTE_SHA256}" "${MOCK_REMOTE_BASENAME}"
fi
EOF
  chmod 0755 "${json_bin}/ssh"

  archive_json="$({
    PATH="${json_bin}:${PATH}" \
    MOCK_REMOTE_BYTES=4096 \
    MOCK_REMOTE_SHA256="${json_sha}" \
    MOCK_REMOTE_BASENAME="${json_basename}" \
      "${RSYNC_FETCH}" \
        --action inspect \
        --remote-host test.example.invalid \
        --remote-path "${json_remote_path}" \
        --identity "${json_identity}" \
        --known-hosts "${json_known_hosts}" \
        --output json
  } 2>"${json_tmp}/archive.log")"
  jq -e \
    --arg basename "${json_basename}" \
    'type == "object"
     and (.bytes | type == "number" and . == 4096 and floor == .)
     and (.sha256 == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
     and (.basename == $basename)
     and (has("path") | not)' <<<"${archive_json}" >/dev/null || \
    fail "rsync inspection did not emit the typed archive JSON contract"

  connection_args_definition="$(awk '
    /^connection_args\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${RUNNER}")"
  inspect_definition="$(awk '
    /^inspect_remote_archive\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${RUNNER}")"
  resolve_source_definition="$(awk '
    /^resolve_source_vm\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${RUNNER}")"
  [[ -n "${connection_args_definition}" && -n "${inspect_definition}" && -n "${resolve_source_definition}" ]] || \
    fail "could not extract the runner JSON inspection path"

  parsed_archive_json="$({
    PATH="${json_bin}:${PATH}" \
    MOCK_REMOTE_BYTES=4096 \
    MOCK_REMOTE_SHA256="${json_sha}" \
    MOCK_REMOTE_BASENAME="${json_basename}" \
      bash -c '
        set -euo pipefail
        source "$1"
        eval "$2"
        eval "$3"
        eval "$4"
        RSYNC_FETCH="$5"
        REMOTE_HOST=test.example.invalid
        REMOTE_USER=root
        REMOTE_PORT=22
        REMOTE_PATH="$6"
        IDENTITY="$7"
        KNOWN_HOSTS="$8"
        CONNECT_TIMEOUT=10
        HOST_KEY_FINGERPRINT=""
        SOURCE_VM_ID=200
        CURRENT_PHASE=test
        inspect_remote_archive
        jq -cn \
          --arg bytes "${REMOTE_BYTES}" \
          --arg sha256 "${REMOTE_SHA256}" \
          --arg basename "${REMOTE_BASENAME}" \
          --arg source_vm "${SOURCE_VM_ID}" \
          "{bytes:(\$bytes|tonumber),sha256:\$sha256,basename:\$basename,source_vm:(\$source_vm|tonumber)}"
      ' _ "${COMMON}" "${connection_args_definition}" "${inspect_definition}" \
        "${resolve_source_definition}" "${RSYNC_FETCH}" "${json_remote_path}" \
        "${json_identity}" "${json_known_hosts}"
  } 2>"${json_tmp}/runner-archive.log")"
  jq -e --arg basename "${json_basename}" \
    '.bytes == 4096 and .source_vm == 200 and .basename == $basename
     and .sha256 == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    <<<"${parsed_archive_json}" >/dev/null || \
    fail "runner did not parse the real rsync helper JSON output"

  cat >"${json_bin}/mock-fetch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${MOCK_JSON}"
EOF
  chmod 0755 "${json_bin}/mock-fetch"
  invalid_archive_json=(
    '{'
    '[]'
    'null'
    $'{"bytes":4096,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","basename":"vzdump-qemu-200-test.vma.zst"}\n{"bytes":4096,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","basename":"vzdump-qemu-200-test.vma.zst"}'
    "{\"bytes\":4096,\"sha256\":\"${json_sha}\"}"
    "{\"bytes\":\"4096\",\"sha256\":\"${json_sha}\",\"basename\":\"vzdump-qemu-200-test.vma.zst\"}"
    "{\"bytes\":0,\"sha256\":\"${json_sha}\",\"basename\":\"vzdump-qemu-200-test.vma.zst\"}"
    "{\"bytes\":-1,\"sha256\":\"${json_sha}\",\"basename\":\"vzdump-qemu-200-test.vma.zst\"}"
    '{"bytes":4096,"sha256":"not-a-sha256","basename":"vzdump-qemu-200-test.vma.zst"}'
    $'{"bytes":4096,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","basename":"bad\nname"}'
  )
  for invalid_json in "${invalid_archive_json[@]}"; do
    set +e
    MOCK_JSON="${invalid_json}" bash -c '
      set -euo pipefail
      source "$1"
      eval "$2"
      eval "$3"
      eval "$4"
      RSYNC_FETCH="$5"
      REMOTE_HOST=test.example.invalid
      REMOTE_USER=root
      REMOTE_PORT=22
      REMOTE_PATH=/backup/vzdump-qemu-200-test.vma.zst
      IDENTITY=/tmp/mock-identity
      KNOWN_HOSTS=/tmp/mock-known-hosts
      CONNECT_TIMEOUT=10
      HOST_KEY_FINGERPRINT=""
      SOURCE_VM_ID=200
      CURRENT_PHASE=test
      inspect_remote_archive
    ' _ "${COMMON}" "${connection_args_definition}" "${inspect_definition}" \
      "${resolve_source_definition}" "${json_bin}/mock-fetch" \
      >"${json_tmp}/invalid.out" 2>"${json_tmp}/invalid.log"
    invalid_rc=$?
    set -e
    [[ "${invalid_rc}" == "${RESTORE_EXIT_TRANSFER:-40}" ]] || \
      fail "invalid archive JSON returned ${invalid_rc}, expected 40"
    grep -q 'malformed or incorrectly typed JSON metadata' "${json_tmp}/invalid.log" || \
      fail "invalid archive JSON did not report a metadata-contract error"
  done

  status_definition="$(awk '
    /^emit_status\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${STORAGE_TEMP}")"
  [[ -n "${status_definition}" ]] || fail "could not extract storage JSON status producer"
  storage_mountpoint="${json_tmp}/mount with \"quotes\" and \\backslash"
  storage_json="$(bash -c '
    set -euo pipefail
    source "$1"
    eval "$2"
    OUTPUT=json
    VG_NAME=pve
    THIN_POOL=data
    LV_NAME=restore_stage_vm100
    STORAGE=local-lvm
    DEVICE=/dev/pve/restore_stage_vm100
    MOUNTPOINT="$3"
    STAGE_BYTES=8192
    POOL_SIZE_BYTES=107374182400
    POOL_DATA_PERCENT=12.5
    POOL_METADATA_PERCENT=1.25
    VG_FREE_BYTES=53687091200
    emit_status present
  ' _ "${COMMON}" "${status_definition}" "${storage_mountpoint}")"
  jq -e --arg mountpoint "${storage_mountpoint}" '
    type == "object"
    and .state == "present"
    and .storage == "local-lvm"
    and .mountpoint == $mountpoint
    and (.stage_bytes == 8192 and (.stage_bytes | type) == "number")
    and (.pool_size_bytes == 107374182400 and (.pool_size_bytes | type) == "number")
    and (.data_percent == 12.5 and (.data_percent | type) == "number")
    and (.metadata_percent == 1.25 and (.metadata_percent | type) == "number")
    and (.vg_free_bytes == 53687091200 and (.vg_free_bytes | type) == "number")
  ' <<<"${storage_json}" >/dev/null || fail "storage status did not emit typed JSON"

  capacity_definition="$(awk '
    /^check_restore_capacity\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${RUNNER}")"
  [[ -n "${capacity_definition}" ]] || fail "could not extract runner storage JSON parser"
  MOCK_JSON="${storage_json}" bash -c '
    set -euo pipefail
    source "$1"
    eval "$2"
    STORAGE_TEMP="$3"
    VM_ID=100
    TARGET_STORAGE=local-lvm
    MOUNT_ROOT=/mnt/pve-restore
    MAX_THIN_DATA_PERCENT=85
    MAX_THIN_METADATA_PERCENT=75
    VMA_ESTIMATED_BYTES=4096
    CAPACITY_OVERRIDE=0
    DRY_RUN=0
    CURRENT_PHASE=test
    check_restore_capacity
  ' _ "${COMMON}" "${capacity_definition}" "${json_bin}/mock-fetch" \
    >"${json_tmp}/capacity.out" 2>"${json_tmp}/capacity.log" || \
    fail "runner did not parse the real storage status JSON"
  invalid_storage_json=(
    '{"pool_size_bytes":0,"data_percent":12.5,"metadata_percent":1.25}'
    '{"pool_size_bytes":107374182400,"data_percent":"12.5","metadata_percent":1.25}'
    '{"pool_size_bytes":107374182400,"data_percent":-1,"metadata_percent":1.25}'
    '{"pool_size_bytes":107374182400,"data_percent":12.5,"metadata_percent":-1}'
    '{"pool_size_bytes":107374182400,"data_percent":12.5}'
  )
  for invalid_json in "${invalid_storage_json[@]}"; do
    set +e
    MOCK_JSON="${invalid_json}" bash -c '
      set -euo pipefail
      source "$1"
      eval "$2"
      STORAGE_TEMP="$3"
      VM_ID=100
      TARGET_STORAGE=local-lvm
      MOUNT_ROOT=/mnt/pve-restore
      MAX_THIN_DATA_PERCENT=85
      MAX_THIN_METADATA_PERCENT=75
      VMA_ESTIMATED_BYTES=4096
      CAPACITY_OVERRIDE=0
      DRY_RUN=0
      CURRENT_PHASE=test
      check_restore_capacity
    ' _ "${COMMON}" "${capacity_definition}" "${json_bin}/mock-fetch" \
      >"${json_tmp}/invalid-capacity.out" 2>"${json_tmp}/invalid-capacity.log"
    invalid_rc=$?
    set -e
    [[ "${invalid_rc}" == "${RESTORE_EXIT_INTEGRITY:-50}" ]] || \
      fail "invalid storage JSON returned ${invalid_rc}, expected 50"
    grep -q 'malformed or incorrectly typed JSON metadata' "${json_tmp}/invalid-capacity.log" || \
      fail "invalid storage JSON did not report a metadata-contract error"
  done

  ssh_json="$({
    PATH="${json_bin}:${PATH}" \
      "${SSH_SYNC}" \
        --action check \
        --remote-host test.example.invalid \
        --remote-port 0022 \
        --identity "${json_identity}" \
        --known-hosts "${json_known_hosts}" \
        --output json
  } 2>"${json_tmp}/ssh.log")"
  jq -e --arg identity "${json_identity}" --arg known_hosts "${json_known_hosts}" '
    type == "object"
    and .host == "test.example.invalid"
    and .user == "root"
    and (.port == 22 and (.port | type) == "number")
    and .identity == $identity
    and .known_hosts == $known_hosts
  ' <<<"${ssh_json}" >/dev/null || fail "SSH helper did not emit typed JSON"

  result_definition="$(awk '
    /^emit_result\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${RUNNER}")"
  [[ -n "${result_definition}" ]] || fail "could not extract final restore JSON producer"
  result_archive="${json_tmp}/archive with \"quotes\" and \\backslash.vma.zst"
  result_json="$(bash -c '
    set -euo pipefail
    source "$1"
    eval "$2"
    OUTPUT=json
    ACTION=all
    VM_ID=100
    SOURCE_VM_ID=200
    ARCHIVE="$3"
    LOCAL_BYTES=4096
    REMOTE_BYTES=4096
    LOCAL_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    REMOTE_SHA256="${LOCAL_SHA256}"
    MOUNT_ROOT=/mnt/pve-restore
    emit_result completed
  ' _ "${COMMON}" "${result_definition}" "${result_archive}")"
  jq -e --arg archive "${result_archive}" '
    type == "object"
    and .action == "all"
    and (.target_vm == 100 and (.target_vm | type) == "number")
    and (.source_vm == 200 and (.source_vm | type) == "number")
    and .archive == $archive
    and (.bytes == 4096 and (.bytes | type) == "number")
    and .sha256 == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ' <<<"${result_json}" >/dev/null || fail "final restore result did not emit typed JSON"

  nullable_result_json="$(bash -c '
    set -euo pipefail
    source "$1"
    eval "$2"
    OUTPUT=json
    ACTION=preflight
    VM_ID=100
    SOURCE_VM_ID=""
    ARCHIVE=""
    LOCAL_BYTES=""
    REMOTE_BYTES=""
    LOCAL_SHA256=""
    REMOTE_SHA256=""
    MOUNT_ROOT=/mnt/pve-restore
    emit_result completed
  ' _ "${COMMON}" "${result_definition}")"
  jq -e '
    .action == "preflight" and .target_vm == 100 and .source_vm == null
    and .archive == null and .bytes == 0 and .sha256 == null
  ' <<<"${nullable_result_json}" >/dev/null || fail "optional restore result fields are not JSON null values"

  rm -rf "${json_tmp}"
  ok "SSH, archive, storage, and final-result JSON contracts are typed, escaped, parsed, and rejected strictly"
else
  ok "JSON integration is deferred to GitHub Actions on Bash 4.3+"
fi

canonical_tmp="$(mktemp -d)"
canonical_identity="${canonical_tmp}/commented-ed25519"
canonical_known_hosts="${canonical_tmp}/known_hosts"
ssh-keygen -q -t ed25519 -N '' -C 'proxmox-restore@canonical-test' -f "${canonical_identity}"
printf 'mock-known-host\n' >"${canonical_known_hosts}"
canonical_setup="$(
  "${SSH_SYNC}" \
    --action setup \
    --remote-host test.example.invalid \
    --identity "${canonical_identity}" \
    --known-hosts "${canonical_known_hosts}" \
    --dry-run 2>&1
)"
grep -q 'ssh-copy-id' <<<"${canonical_setup}" || fail "commented ssh-keygen output was not accepted as the matching public key"
rm -rf "${canonical_tmp}"
ok "public-key comparison ignores OpenSSH comments and matches canonical key material"

if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3))); then
  rotation_tmp="$(mktemp -d)"
  rotation_bin="${rotation_tmp}/bin"
  rotation_remote="${rotation_tmp}/remote"
  rotation_identity="${rotation_tmp}/proxmox-restore-ed25519"
  rotation_known_hosts="${rotation_tmp}/known_hosts"
  stale_identity="${rotation_tmp}/stale-ed25519"
  unrelated_identity="${rotation_tmp}/unrelated-ed25519"
  mkdir -p "${rotation_bin}" "${rotation_remote}/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C 'old-private' -f "${rotation_identity}"
  ssh-keygen -q -t ed25519 -N '' -C 'stale-public' -f "${stale_identity}"
  ssh-keygen -q -t ed25519 -N '' -C 'unrelated' -f "${unrelated_identity}"
  old_private_material="$(ssh-keygen -y -f "${rotation_identity}" | awk 'NF >= 2 {print $1 " " $2; exit}')"
  stale_material="$(awk 'NF >= 2 {print $1 " " $2; exit}' "${stale_identity}.pub")"
  unrelated_material="$(awk 'NF >= 2 {print $1 " " $2; exit}' "${unrelated_identity}.pub")"
  old_private_blob="${old_private_material#* }"
  stale_blob="${stale_material#* }"
  unrelated_blob="${unrelated_material#* }"
  cp "${stale_identity}.pub" "${rotation_identity}.pub"
  printf 'mock-known-host\n' >"${rotation_known_hosts}"
  printf 'from="test.example.invalid" %s old-private\n%s stale-public\n%s unrelated\n' \
    "${old_private_material}" "${stale_material}" "${unrelated_material}" \
    >"${rotation_remote}/.ssh/authorized_keys"
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
  chmod 0755 "${rotation_bin}/ssh-copy-id" "${rotation_bin}/ssh"

  set +e
  PATH="${rotation_bin}:${PATH}" \
  MOCK_REMOTE_AUTHORIZED_KEYS="${rotation_remote}/.ssh/authorized_keys" \
    "${SSH_SYNC}" \
      --action setup \
      --remote-host test.example.invalid \
      --identity "${rotation_identity}" \
      --known-hosts "${rotation_known_hosts}" >/dev/null 2>"${rotation_tmp}/mismatch.log"
  mismatch_rc=$?
  set -e
  [[ "${mismatch_rc}" == "${RESTORE_EXIT_SSH:-20}" ]] || fail "ordinary mismatched-pair setup returned ${mismatch_rc}, expected 20"
  grep -q 'does not match' "${rotation_tmp}/mismatch.log" || fail "ordinary setup did not reject the mismatched pair"

  old_private_checksum="$(cksum < "${rotation_identity}")"
  old_public_checksum="$(cksum < "${rotation_identity}.pub")"

  set +e
  PATH="${rotation_bin}:${PATH}" \
  MOCK_REMOTE_AUTHORIZED_KEYS="${rotation_remote}/.ssh/authorized_keys" \
  MOCK_SSH_COPY_ID_FAIL=1 \
    "${SSH_SYNC}" \
      --action setup \
      --remote-host test.example.invalid \
      --identity "${rotation_identity}" \
      --known-hosts "${rotation_known_hosts}" \
      --key-rotation \
      --yes >/dev/null 2>"${rotation_tmp}/failed-rotation.log"
  failed_rotation_rc=$?
  set -e
  [[ "${failed_rotation_rc}" == "${RESTORE_EXIT_SSH:-20}" ]] || fail "failed key installation returned ${failed_rotation_rc}, expected 20"
  [[ "$(cksum < "${rotation_identity}")" == "${old_private_checksum}" ]] || fail "failed key installation changed the old private key"
  [[ "$(cksum < "${rotation_identity}.pub")" == "${old_public_checksum}" ]] || fail "failed key installation changed the old public key"
  if compgen -G "${rotation_identity}.rotation-new.*" >/dev/null; then
    fail "failed key installation retained temporary new-key material"
  fi

  PATH="${rotation_bin}:${PATH}" \
  MOCK_REMOTE_AUTHORIZED_KEYS="${rotation_remote}/.ssh/authorized_keys" \
    "${SSH_SYNC}" \
      --action setup \
      --remote-host test.example.invalid \
      --identity "${rotation_identity}" \
      --known-hosts "${rotation_known_hosts}" \
      --key-rotation \
      --yes >/dev/null 2>"${rotation_tmp}/rotation.log"

  rotated_private_material="$(ssh-keygen -y -f "${rotation_identity}" | awk 'NF >= 2 {print $1 " " $2; exit}')"
  rotated_public_material="$(awk 'NF >= 2 {print $1 " " $2; exit}' "${rotation_identity}.pub")"
  rotated_blob="${rotated_private_material#* }"
  [[ "${rotated_private_material}" == "${rotated_public_material}" ]] || fail "key rotation installed a mismatched local pair"
  grep -Fq -- "${rotated_blob}" "${rotation_remote}/.ssh/authorized_keys" || fail "key rotation did not install the fresh remote key"
  grep -Fq -- "${unrelated_blob}" "${rotation_remote}/.ssh/authorized_keys" || fail "key rotation removed an unrelated remote key"
  if grep -Fq -e "${old_private_blob}" -e "${stale_blob}" "${rotation_remote}/.ssh/authorized_keys"; then
    fail "key rotation retained old remote key material"
  fi
  if compgen -G "${rotation_identity}.rotation-new.*" >/dev/null \
    || compgen -G "${rotation_identity}.rotation-old.*" >/dev/null \
    || compgen -G "${rotation_identity}.pub.rotation-old.*" >/dev/null; then
    fail "key rotation retained temporary or old local key material after success"
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
expect_exit 2 "${RUNNER}" --remote --action transfer --vm 100 --remote-host 192.0.2.1 \
  --remote-path /backup/vzdump-qemu-200-test.vma.zst --reset-incomplete-stage
expect_exit 2 "${RUNNER}" --remote --action preflight --vm 100 --remote-host 192.0.2.1 \
  --remote-path /backup/vzdump-qemu-200-test.vma.zst --reset-incomplete-stage --yes
expect_exit 2 "${STORAGE_TEMP}" --action create --vm 100 --source-bytes 4096 --reset-incomplete-stage
expect_exit 2 "${STORAGE_TEMP}" --action status --vm 100 --reset-incomplete-stage --yes
expect_exit 2 "${RUNNER}" --action preflight --vm 100 --output tsv
expect_exit 2 "${SSH_SYNC}" --action check --remote-host 192.0.2.1 --output tsv
expect_exit 2 "${STORAGE_TEMP}" --action status --vm 100 --output tsv
expect_exit 2 "${RSYNC_FETCH}" --action inspect --remote-host 192.0.2.1 --remote-path /backup/vzdump-qemu-200-test.vma.zst --output tsv
expect_exit 2 "${RUNNER}" positional
expect_exit 2 "${RUNNER}" --action all --vm 100
expect_exit 2 "${RUNNER}" --remote --local --action all --vm 100 \
  --remote-host 192.0.2.1 --remote-path /backup/vzdump-qemu-200-test.vma.zst
expect_exit 2 "${RUNNER}" --local --action all --vm 100 --archive /backup/vzdump-qemu-200-test.vma.zst
expect_exit 2 "${RUNNER}" --local --action transfer --vm 100 --archive-path /backup/vzdump-qemu-200-test.vma.zst
expect_exit 2 "${RUNNER}" --remote --action verify --vm 100 --remote-host 192.0.2.1 \
  --remote-path /backup/vzdump-qemu-200-test.vma.zst
expect_exit 2 "${RUNNER}" --action cleanup --vm 100 --local
expect_exit 2 "${RUNNER}" --local --action all --vm 100 --archive-path relative/vzdump-qemu-200-test.vma.zst
expect_exit 2 "${RUNNER}" --local --action all --vm 100 --archive-path /backup/not-a-vma.tar
expect_exit 2 "${RUNNER}" --local --action all --vm 100 --archive-path /backup/vzdump-qemu-200-test.vma.zst \
  --remote-host 192.0.2.1
expect_exit 2 "${RUNNER}" --local --action all --vm 100 --archive-path /backup/vzdump-qemu-200-test.vma.zst \
  --stage-storage local-lvm
expect_exit 2 "${RUNNER}" --local --action all --vm 100 --archive-path /backup/vzdump-qemu-200-test.vma.zst \
  --rsync-bwlimit-kbps 1000
expect_exit 10 "${RUNNER}" --remote --action preflight --vm 100 --remote-host 192.0.2.1 \
  --remote-path /backup/vzdump-qemu-200-test.vma.zst
expect_exit 10 "${RUNNER}" --local --action preflight --vm 100 \
  --archive-path /backup/vzdump-qemu-200-test.vma.zst
ok "source modes, action matrix, retired flags, and malformed arguments enforce their exit contracts"

local_source_tmp="$(mktemp -d)"
local_archive="${local_source_tmp}/vzdump-qemu-200-local-test.vma"
local_symlink="${local_source_tmp}/vzdump-qemu-200-symlink-test.vma"
local_directory="${local_source_tmp}/vzdump-qemu-200-directory-test.vma"
printf 'local-vma-fixture\n' >"${local_archive}"
ln -s "${local_archive}" "${local_symlink}"
mkdir "${local_directory}"
inspect_local_definition="$(awk '
  /^inspect_local_archive\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "${RUNNER}")"
resolve_source_definition="$(awk '
  /^resolve_source_vm\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "${RUNNER}")"
preflight_definition="$(awk '
  /^run_preflight\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "${RUNNER}")"
[[ -n "${inspect_local_definition}" && -n "${resolve_source_definition}" && -n "${preflight_definition}" ]] || \
  fail "could not extract local-source runner functions"

bash -c '
  set -euo pipefail
  source "$1"
  eval "$2"
  eval "$3"
  SOURCE_MODE=local
  SOURCE_VM_ID=200
  ARCHIVE_PATH="$4"
  ARCHIVE=""
  LOCAL_BYTES=""
  CURRENT_PHASE=test
  inspect_local_archive
  [[ "${ARCHIVE}" == "${ARCHIVE_PATH}" && "${LOCAL_BYTES}" -gt 0 && "${SOURCE_VM_ID}" == 200 ]]
' _ "${COMMON}" "${resolve_source_definition}" "${inspect_local_definition}" "${local_archive}" || \
  fail "local archive inspection did not accept a valid regular archive"

for invalid_local in "${local_symlink}" "${local_directory}" "${local_source_tmp}/vzdump-qemu-200-missing-test.vma"; do
  set +e
  bash -c '
    set -euo pipefail
    source "$1"
    eval "$2"
    eval "$3"
    SOURCE_MODE=local
    SOURCE_VM_ID=200
    ARCHIVE_PATH="$4"
    ARCHIVE=""
    LOCAL_BYTES=""
    CURRENT_PHASE=test
    inspect_local_archive
  ' _ "${COMMON}" "${resolve_source_definition}" "${inspect_local_definition}" "${invalid_local}" \
    >"${local_source_tmp}/invalid.out" 2>"${local_source_tmp}/invalid.log"
  invalid_local_rc=$?
  set -e
  [[ "${invalid_local_rc}" == 50 ]] || fail "invalid local archive returned ${invalid_local_rc}, expected 50"
done

if ((EUID != 0)); then
  unreadable_local="${local_source_tmp}/vzdump-qemu-200-unreadable-test.vma"
  printf 'unreadable-fixture\n' >"${unreadable_local}"
  chmod 000 "${unreadable_local}"
  set +e
  bash -c '
    set -euo pipefail
    source "$1"
    eval "$2"
    eval "$3"
    SOURCE_MODE=local
    SOURCE_VM_ID=200
    ARCHIVE_PATH="$4"
    ARCHIVE=""
    LOCAL_BYTES=""
    CURRENT_PHASE=test
    inspect_local_archive
  ' _ "${COMMON}" "${resolve_source_definition}" "${inspect_local_definition}" "${unreadable_local}" \
    >"${local_source_tmp}/unreadable.out" 2>"${local_source_tmp}/unreadable.log"
  unreadable_rc=$?
  set -e
  chmod 0600 "${unreadable_local}"
  [[ "${unreadable_rc}" == 50 ]] || fail "unreadable local archive returned ${unreadable_rc}, expected 50"
fi

set +e
bash -c '
  set -euo pipefail
  source "$1"
  eval "$2"
  eval "$3"
  SOURCE_MODE=local
  SOURCE_VM_ID=201
  ARCHIVE_PATH="$4"
  ARCHIVE=""
  LOCAL_BYTES=""
  CURRENT_PHASE=test
  inspect_local_archive
' _ "${COMMON}" "${resolve_source_definition}" "${inspect_local_definition}" "${local_archive}" \
  >"${local_source_tmp}/mismatch.out" 2>"${local_source_tmp}/mismatch.log"
local_mismatch_rc=$?
set -e
[[ "${local_mismatch_rc}" == 50 ]] || fail "local source-VM mismatch returned ${local_mismatch_rc}, expected 50"

required_log="${local_source_tmp}/required.log"
preflight_log="${local_source_tmp}/preflight.log"
REQUIRED_LOG="${required_log}" bash -c '
  set -euo pipefail
  source "$1"
  eval "$2"
  eval "$3"
  eval "$4"
  restore.require_proxmox() { :; }
  restore.require_commands() { shift; printf "%s\n" "$*" >>"${REQUIRED_LOG}"; }
  restore.acquire_lock() { :; }
  pvesm() { printf "Name Type Status\nlocal-lvm lvmthin active\n"; }
  SOURCE_MODE=local
  ACTION=preflight
  VM_ID=100
  SOURCE_VM_ID=200
  ARCHIVE_PATH="$5"
  ARCHIVE=""
  LOCAL_BYTES=""
  TARGET_STORAGE=local-lvm
  STAGE_STORAGE=local-lvm
  MOUNT_ROOT=/mnt/pve-restore
  MAX_THIN_DATA_PERCENT=85
  MAX_THIN_METADATA_PERCENT=75
  DRY_RUN=0
  SSH_SYNC=/bin/false
  STORAGE_TEMP=/bin/false
  PLAYBOOK_PATH=/tmp/vm.restore.yml
  CURRENT_PHASE=test
  run_preflight
' _ "${COMMON}" "${resolve_source_definition}" "${inspect_local_definition}" "${preflight_definition}" "${local_archive}" \
  >"${local_source_tmp}/preflight.out" 2>"${preflight_log}" || \
  fail "local preflight invoked a remote or staging dependency"
if grep -Eq '(^| )(ssh|rsync|lvcreate|mkfs\.ext4)( |$)' "${required_log}"; then
  fail "local preflight requires remote transport or stage-creation commands"
fi
if grep -Eq 'checking stage storage|passwordless SSH' "${preflight_log}"; then
  fail "local preflight entered a remote staging or SSH phase"
fi

verify_definition="$(awk '
  /^verify_archive\(\) \{/ { capture=1 }
  /^check_restore_capacity\(\) \{/ { exit }
  capture { print }
' "${RUNNER}")"
[[ -n "${verify_definition}" ]] || fail "could not extract local archive verification"
local_manifest="${local_source_tmp}/.proxmox-restore.tsv"
printf 'target_vm\t999\n' >"${local_manifest}"
manifest_before="$(sha256sum "${local_manifest}")"
bash -c '
  set -euo pipefail
  source "$1"
  eval "$2"
  eval "$3"
  vma() {
    printf "DEV: dev_id: 0 size: 4096\n"
    printf "qemu-server.conf\n"
    printf "total bytes read 4096\n"
  }
  SOURCE_MODE=local
  SOURCE_VM_ID=200
  VM_ID=100
  ARCHIVE="$4"
  ACTIVE_MANIFEST=""
  LOCAL_BYTES=""
  LOCAL_SHA256=""
  VMA_DEVICE_BYTES=0
  VMA_SPARSE_BYTES=0
  VMA_STREAM_BYTES=0
  VMA_ESTIMATED_BYTES=0
  DRY_RUN=0
  CURRENT_PHASE=test
  verify_archive
  [[ -z "${ACTIVE_MANIFEST}" && "${LOCAL_BYTES}" -gt 0 && "${LOCAL_SHA256}" =~ ^[0-9a-f]{64}$ ]]
' _ "${COMMON}" "${resolve_source_definition}" "${verify_definition}" "${local_archive}" \
  >"${local_source_tmp}/verify.out" 2>"${local_source_tmp}/verify.log" || \
  fail "local verification adopted a neighboring manifest or failed its integrity path"
manifest_after="$(sha256sum "${local_manifest}")"
[[ "${manifest_after}" == "${manifest_before}" ]] || fail "local verification modified a neighboring manifest"
rm -rf "${local_source_tmp}"
ok "local archives are validated without SSH, rsync, staging, manifest adoption, or mutation"

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
grep -q 'blkid --probe --output export' "${STORAGE_TEMP}" || fail "filesystem verification does not use authoritative blkid probing"
grep -q 'udevadm settle --timeout=10' "${STORAGE_TEMP}" || fail "storage lifecycle does not synchronize with udev"
grep -q -- '--addtag "${LV_OWNER_TAG}" --addtag "${LV_VM_TAG}"' "${STORAGE_TEMP}" || fail "new stages lack ownership tags"
grep -q 'trap rollback_new_stage EXIT' "${STORAGE_TEMP}" || fail "new-stage creation lacks transactional rollback"
grep -q 'reset_incomplete_stage' "${STORAGE_TEMP}" || fail "guarded incomplete-stage recovery is missing"
ok "temporary-storage ownership, probing, recovery, and cleanup boundaries are present"

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
inspection_line="$(grep -n '^  inspect_remote_archive$' "${RUNNER}" | cut -d: -f1)"
staging_line="$(grep -n '^  CURRENT_PHASE="staging"$' "${RUNNER}" | cut -d: -f1)"
stage_create_line="$(grep -n 'stage_dir="$(restore.child "${STORAGE_TEMP}" --action create' "${RUNNER}" | cut -d: -f1)"
[[ -n "${inspection_line}" && -n "${staging_line}" && -n "${stage_create_line}" \
  && "${inspection_line}" -lt "${staging_line}" && "${staging_line}" -lt "${stage_create_line}" ]] || \
  fail "remote inspection and staging phases are not ordered accurately"
grep -q 'no verified staging archive was retained' "${RUNNER}" || fail "pre-manifest failure reporting is not explicit"
grep -q 'restore.child' "${RUNNER}" || fail "runner does not isolate its lock descriptor from helpers"
grep -q 'the local archive was left untouched' "${RUNNER}" || fail "local failure retention is not explicit"
grep -q '\[\[ "${SOURCE_MODE}" == remote && -f "${manifest}"' "${RUNNER}" || \
  fail "local verification can adopt a neighboring stage manifest"
all_action_definition="$(awk '
  /^  all\)/ { capture=1 }
  capture { print }
  capture && /^    ;;/ { exit }
' "${RUNNER}")"
[[ -n "${all_action_definition}" ]] || fail "could not extract the all-action source switch"
grep -q '\[\[ "${SOURCE_MODE}" == remote \]\]' <<<"${all_action_definition}" || \
  fail "all action does not gate transfer behind remote mode"
grep -q 'SOURCE_MODE.*remote.*CLEANUP_POLICY' <<<"${all_action_definition}" || \
  fail "all action does not gate staging cleanup behind remote mode"
if grep -q -- '--archive)' "${RUNNER}"; then
  fail "runner still parses the retired --archive flag"
fi
ok "source-aware retention, manifest isolation, phase reporting, lock isolation, and cleanup ordering are explicit"

grep -q 'FEATURE_PLAYBOOKS=(' "${RUNNER}" || fail "runner does not declare playbook dependencies"
grep -q 'FEATURE_CLI_FILES=(' "${RUNNER}" || fail "runner does not declare CLI dependencies"
for cli_ref in lib/restore.common.sh ssh/sync.sh storage/temp.sh rsync/fetch.sh; do
  grep -q "\"${cli_ref}\"" "${RUNNER}" || fail "runner is missing .sh CLI dependency: ${cli_ref}"
done
grep -q 'case "${ACTION}" in' "${STORAGE_TEMP}" || fail "storage helper does not scope command dependencies by action"
if grep -Eq '"(lib/restore\.common|ssh/sync|storage/temp|rsync/fetch)"' "${RUNNER}"; then
  fail "runner retains an extensionless CLI dependency"
fi
if grep -R -E -q -- '--output[[:space:]]+tsv|human\|[^[:space:]]*tsv|parse_tsv|local[[:space:]]+tsv=|restore\.emit.*tsv' \
  "${RUNNER}" "${ROOT}/cli" "${ROOT}/docs/setup/vm/restore.md" "${ROOT}/docs/cli" "${ROOT}/readme.md"; then
  fail "published restore interfaces retain the removed TSV machine-output contract"
fi
if grep -R -i -q -- 'tsv' \
  "${ROOT}/docs/setup/vm/restore.md" "${ROOT}/docs/cli/rsync/fetch.md" \
  "${ROOT}/docs/cli/ssh/sync.md" "${ROOT}/docs/cli/storage/temp.md" "${ROOT}/readme.md"; then
  fail "restore documentation retains references to the removed machine-output format"
fi
grep -qx 'setup/vm/restore.sh|setup/vm/restore.sh|feature' "${ROOT}/actions/pages.features.txt" || fail "Pages manifest lacks canonical VM restore runner"
grep -q 'FEATURE_MANIFEST="actions/pages.features.txt"' "${ROOT}/actions/www.pages.sh" || fail "Pages publisher does not consume the feature manifest"
grep -q 'check_feature_manifest' "${ROOT}/actions/validate.pages.sh" || fail "Pages validator does not validate the feature manifest"
if rg -n 'SETUP_VM_RESTORE_RUNNER' "${ROOT}/actions/www.pages.sh" "${ROOT}/actions/validate.pages.sh" >/dev/null; then
  fail "VM restore publication still uses feature-specific publisher wiring"
fi
grep -q "'cli/\*\*'" "${ROOT}/.github/workflows/www.pages.yml" || fail "Pages workflow does not trigger on cli/**"
grep -q "'setup/vm/\*\*'" "${ROOT}/.github/workflows/www.pages.yml" || fail "Pages workflow does not explicitly trigger on setup/vm/**"
ok "runner, helper, playbook, validation, and workflow publishing are wired"

if grep -q 'ansible.builtin.shell' "${PLAYBOOK}"; then
  fail "dependency playbook contains shell mutation logic"
fi
grep -q 'ansible.builtin.apt' "${PLAYBOOK}" || fail "dependency playbook does not install packages"
for package in rsync openssh-client lvm2 e2fsprogs findutils util-linux udev zstd jq; do
  grep -q -- "- ${package}" "${PLAYBOOK}" || fail "dependency playbook missing ${package}"
done
grep -A80 'dev_tools:' "${ROOT}/ansible/debian/packages.yml" | grep -q -- '- jq' || \
  fail "Debian dev_tools does not include jq"
ok "Ansible playbook remains dependency-only"

printf '[validate.vm.restore] all contracts passed\n'
