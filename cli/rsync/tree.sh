#!/usr/bin/env bash
## Copy trees and monitor long-running jobs through the restricted LXC SSH service.

set -euo pipefail

ACTION="${1:-}"
SSH_WRAPPER="${PROXMOX_LXC_TRANSFER_SSH_WRAPPER:-/usr/local/sbin/proxmox-transfer-ssh}"
SELECTION_PATH="${PROXMOX_LXC_TRANSFER_SELECTION_PATH:-/etc/ansible/proxmox/facts/lxc.transfer.selection.yml}"
JOB_STATE_DIR="${PROXMOX_LXC_TRANSFER_JOB_STATE_DIR:-/var/lib/proxmox-transfer/jobs}"
JOB_LOG_DIR="${PROXMOX_LXC_TRANSFER_JOB_LOG_DIR:-/var/log/proxmox-transfer}"
LOCAL_ROOT="${PROXMOX_LXC_TRANSFER_LOCAL_ROOT:-}"
SELF_PATH="$(realpath -e -- "${BASH_SOURCE[0]}")"

die() { printf '[proxmox-transfer-rsync][error] %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
usage:
  ${0} push LOCAL_PATH PEER_IPV4:RELATIVE_PATH
  ${0} pull PEER_IPV4:RELATIVE_PATH LOCAL_PATH
  ${0} verify-push LOCAL_PATH PEER_IPV4:RELATIVE_PATH
  ${0} verify-pull PEER_IPV4:RELATIVE_PATH LOCAL_PATH
  ${0} backup-push LOCAL_PATH PEER_IPV4:RELATIVE_PATH
  ${0} backup-pull PEER_IPV4:RELATIVE_PATH LOCAL_PATH
  ${0} verify-backup-push LOCAL_PATH PEER_IPV4:RELATIVE_PATH
  ${0} verify-backup-pull PEER_IPV4:RELATIVE_PATH LOCAL_PATH
  ${0} start-backup-push JOB LOCAL_PATH PEER_IPV4:RELATIVE_PATH
  ${0} start-backup-pull JOB PEER_IPV4:RELATIVE_PATH LOCAL_PATH
  ${0} status JOB [--output text|json]
  ${0} watch JOB
  ${0} log JOB
  ${0} list
EOF
  exit 2
}

require.runtime() {
  [[ -x "${SSH_WRAPPER}" ]] || die "Missing SSH wrapper: ${SSH_WRAPPER}"
  command -v rsync >/dev/null 2>&1 || die 'rsync is required.'
  command -v python3 >/dev/null 2>&1 || die 'python3 is required.'
  [[ -r "${SELECTION_PATH}" ]] || die "Missing transfer selection: ${SELECTION_PATH}"
}

validate.remote() {
  python3 - "$1" "${SELECTION_PATH}" <<'PY'
import ipaddress, json, pathlib, re, sys
try:
    endpoint, path = sys.argv[1].split(":", 1)
    peer = ipaddress.IPv4Address(endpoint)
except (ValueError, IndexError):
    raise SystemExit(1)
selection = json.loads(pathlib.Path(sys.argv[2]).read_text())["proxmox_lxc_transfer_operator_selection"]
allowed = ipaddress.ip_network(selection["allow_cidr"], strict=False)
local = ipaddress.ip_interface(selection["local_cidr"])
service_user = str(selection["service_user"])
if (local.network != allowed or peer not in allowed or peer == local.ip
        or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,30}", service_user)):
    raise SystemExit(1)
candidate = pathlib.PurePosixPath(path)
if path.startswith("/") or not path or ".." in candidate.parts:
    raise SystemExit(1)
print(endpoint)
print(path)
print(service_user)
PY
}

validate.local() {
  python3 - "$1" "${SELECTION_PATH}" "${LOCAL_ROOT}" <<'PY'
import json, pathlib, sys
candidate = pathlib.Path(sys.argv[1])
selection = json.loads(pathlib.Path(sys.argv[2]).read_text())["proxmox_lxc_transfer_operator_selection"]
selected_root = sys.argv[3] or str(selection["transfer_root"])
root_candidate = pathlib.Path(selected_root)
if (not root_candidate.is_absolute() or selected_root == "/" or root_candidate.is_symlink()
        or not root_candidate.is_dir()):
    raise SystemExit(1)
root = root_candidate.resolve(strict=True)
resolved = candidate.resolve(strict=True)
try:
    resolved.relative_to(root)
except ValueError:
    raise SystemExit(1)
if candidate.is_symlink():
    raise SystemExit(1)
PY
}

validate.job.name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$ ]] \
    || die 'JOB must use 1-48 letters, digits, dots, underscores, or hyphens.'
}

parse.remote() {
  local value="$1" parsed
  parsed="$(validate.remote "${value}")" || die "Invalid remote endpoint or relative path: ${value}"
  mapfile -t REMOTE_FIELDS <<< "${parsed}"
  ((${#REMOTE_FIELDS[@]} == 3)) || die 'Remote endpoint parsing returned incomplete data.'
}

validate.operation() {
  local action="$1" source="$2" destination="$3"
  case "${action}" in
    push|verify-push|backup-push|verify-backup-push)
      [[ -e "${source}" ]] || die "Local source does not exist: ${source}"
      validate.local "${source}" || die 'Local source must be within the selected transfer root.'
      parse.remote "${destination}"
      ;;
    pull|verify-pull|backup-pull|verify-backup-pull)
      [[ -d "${destination}" ]] || die "Local destination directory does not exist: ${destination}"
      validate.local "${destination}" || die 'Local destination must be within the selected transfer root.'
      parse.remote "${source}"
      ;;
    *) usage ;;
  esac
}

run.transfer() {
  local action="$1" source="$2" destination="$3"
  local -a common_args metadata_args backup_args verify_args
  validate.operation "${action}" "${source}" "${destination}"
  common_args=(--safe-links --human-readable -e "${SSH_WRAPPER}" --)
  metadata_args=(-rlptHAXS)
  backup_args=(-rltHXS --no-perms --no-acls '--chmod=Du+rwx,Dg+rwx,Fu+rw,Fg+rw')
  verify_args=(--dry-run --checksum --itemize-changes --stats)

  case "${action}" in
    push)
      exec rsync "${metadata_args[@]}" --partial --info=progress2 \
        "${common_args[@]}" "${source}" "${REMOTE_FIELDS[2]}@${REMOTE_FIELDS[0]}:${REMOTE_FIELDS[1]}"
      ;;
    verify-push)
      exec rsync "${metadata_args[@]}" "${verify_args[@]}" \
        "${common_args[@]}" "${source}" "${REMOTE_FIELDS[2]}@${REMOTE_FIELDS[0]}:${REMOTE_FIELDS[1]}"
      ;;
    backup-push)
      exec rsync "${backup_args[@]}" --partial --info=progress2 \
        "${common_args[@]}" "${source}" "${REMOTE_FIELDS[2]}@${REMOTE_FIELDS[0]}:${REMOTE_FIELDS[1]}"
      ;;
    verify-backup-push)
      exec rsync "${backup_args[@]}" "${verify_args[@]}" \
        "${common_args[@]}" "${source}" "${REMOTE_FIELDS[2]}@${REMOTE_FIELDS[0]}:${REMOTE_FIELDS[1]}"
      ;;
    pull)
      exec rsync "${metadata_args[@]}" --partial --info=progress2 \
        "${common_args[@]}" "${REMOTE_FIELDS[2]}@${REMOTE_FIELDS[0]}:${REMOTE_FIELDS[1]}" "${destination}"
      ;;
    verify-pull)
      exec rsync "${metadata_args[@]}" "${verify_args[@]}" \
        "${common_args[@]}" "${REMOTE_FIELDS[2]}@${REMOTE_FIELDS[0]}:${REMOTE_FIELDS[1]}" "${destination}"
      ;;
    backup-pull)
      exec rsync "${backup_args[@]}" --partial --info=progress2 \
        "${common_args[@]}" "${REMOTE_FIELDS[2]}@${REMOTE_FIELDS[0]}:${REMOTE_FIELDS[1]}" "${destination}"
      ;;
    verify-backup-pull)
      exec rsync "${backup_args[@]}" "${verify_args[@]}" \
        "${common_args[@]}" "${REMOTE_FIELDS[2]}@${REMOTE_FIELDS[0]}:${REMOTE_FIELDS[1]}" "${destination}"
      ;;
  esac
}

job.state.path() { printf '%s/%s.json\n' "${JOB_STATE_DIR}" "$1"; }
job.log.path() { printf '%s/%s.log\n' "${JOB_LOG_DIR}" "$1"; }

prepare.job.directories() {
  install -d -m 0700 "${JOB_STATE_DIR}" "${JOB_LOG_DIR}"
}

write.job.state() {
  local job="$1" operation="$2" source="$3" destination="$4" session="$5"
  local status="$6" runner_pid="$7" rsync_pid="$8" started_at="$9" started_epoch="${10}"
  local finished_at="${11:-}" finished_epoch="${12:-}" exit_code="${13:-}"
  local state_path log_path
  state_path="$(job.state.path "${job}")"
  log_path="$(job.log.path "${job}")"
  python3 - "${state_path}" "${job}" "${operation}" "${source}" "${destination}" "${session}" \
    "${status}" "${runner_pid}" "${rsync_pid}" "${started_at}" "${started_epoch}" \
    "${finished_at}" "${finished_epoch}" "${exit_code}" "${log_path}" <<'PY'
import json, os, pathlib, sys

(path, job, operation, source, destination, session, status, runner_pid,
 rsync_pid, started_at, started_epoch, finished_at, finished_epoch,
 exit_code, log_path) = sys.argv[1:]

def number(value):
    return int(value) if value else None

data = {
    "schema_version": 1,
    "job": job,
    "operation": operation,
    "source": source,
    "destination": destination,
    "screen_session": session,
    "status": status,
    "runner_pid": number(runner_pid),
    "rsync_pid": number(rsync_pid),
    "started_at": started_at or None,
    "started_epoch": number(started_epoch),
    "finished_at": finished_at or None,
    "finished_epoch": number(finished_epoch),
    "exit_code": number(exit_code),
    "log_path": log_path,
}
target = pathlib.Path(path)
temporary = target.with_name(target.name + f".tmp.{os.getpid()}")
temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
temporary.chmod(0o600)
os.replace(temporary, target)
PY
}

run.job() {
  local job="$1" operation="$2" source="$3" destination="$4" session="$5"
  local started_at="$6" started_epoch="$7" rsync_pid rc finished_at finished_epoch status
  prepare.job.directories
  "${SELF_PATH}" "${operation}" "${source}" "${destination}" &
  rsync_pid=$!
  write.job.state "${job}" "${operation}" "${source}" "${destination}" "${session}" \
    running "$$" "${rsync_pid}" "${started_at}" "${started_epoch}"
  set +e
  wait "${rsync_pid}"
  rc=$?
  set -e
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  finished_epoch="$(date +%s)"
  if ((rc == 0)); then status=completed; else status=failed; fi
  write.job.state "${job}" "${operation}" "${source}" "${destination}" "${session}" \
    "${status}" "$$" "${rsync_pid}" "${started_at}" "${started_epoch}" \
    "${finished_at}" "${finished_epoch}" "${rc}"
  printf '\nproxmox_transfer_job=%s status=%s exit_code=%s finished=%s\n' \
    "${job}" "${status}" "${rc}" "${finished_at}"
  exit "${rc}"
}

start.job() {
  local operation="$1" job="$2" source="$3" destination="$4"
  local session state_path log_path started_at started_epoch
  require.runtime
  validate.job.name "${job}"
  validate.operation "${operation}" "${source}" "${destination}"
  command -v screen >/dev/null 2>&1 || die 'GNU Screen is required for managed background transfers.'
  command -v pgrep >/dev/null 2>&1 || die 'pgrep is required for managed background transfers.'
  prepare.job.directories
  state_path="$(job.state.path "${job}")"
  log_path="$(job.log.path "${job}")"
  [[ ! -e "${state_path}" && ! -e "${log_path}" ]] \
    || die "Job ${job} already has state or a log; choose a new job name."
  ! pgrep -x rsync >/dev/null 2>&1 \
    || die 'An rsync process is already active; concurrent transfer jobs are refused.'
  session="pxfer-${job}"
  ! screen -ls 2>/dev/null | grep -Fq ".${session}" \
    || die "Screen session ${session} already exists."
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  started_epoch="$(date +%s)"
  : > "${log_path}"
  chmod 0600 "${log_path}"
  write.job.state "${job}" "${operation}" "${source}" "${destination}" "${session}" \
    queued "$$" '' "${started_at}" "${started_epoch}"
  if ! screen -DmS "${session}" -L -Logfile "${log_path}" \
      "${SELF_PATH}" __run-job "${job}" "${operation}" "${source}" "${destination}" \
      "${session}" "${started_at}" "${started_epoch}"; then
    write.job.state "${job}" "${operation}" "${source}" "${destination}" "${session}" \
      failed "$$" '' "${started_at}" "${started_epoch}" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" 1
    die "Unable to start Screen session ${session}."
  fi
  printf 'Started transfer job %s in screen session %s.\n' "${job}" "${session}"
  printf 'Status: %s status %s\n' "${SELF_PATH}" "${job}"
  printf 'Live view: %s watch %s\n' "${SELF_PATH}" "${job}"
  printf 'Log: %s log %s\n' "${SELF_PATH}" "${job}"
}

status.job() {
  local job="$1" output="${2:-text}" state_path
  validate.job.name "${job}"
  [[ "${output}" == text || "${output}" == json ]] || die 'Status output must be text or json.'
  state_path="$(job.state.path "${job}")"
  [[ -r "${state_path}" ]] || die "No state exists for job ${job}."
  python3 - "${state_path}" "${output}" <<'PY'
import json, os, pathlib, re, sys, time

state_path, output = sys.argv[1:]
state = json.loads(pathlib.Path(state_path).read_text())
pid = state.get("rsync_pid")
status = state.get("status", "unknown")
queued_grace = status == "queued" and int(time.time()) - (state.get("started_epoch") or 0) <= 15
if status in {"queued", "running"} and not queued_grace \
        and (not pid or not pathlib.Path(f"/proc/{pid}").exists()):
    status = "stale"

progress = None
log_path = pathlib.Path(state["log_path"])
if log_path.is_file():
    with log_path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        handle.seek(max(0, size - 2 * 1024 * 1024))
        text = handle.read().decode("utf-8", "replace")
    pattern = re.compile(
        r"^\s*([0-9.,]+[KMGTPE]?B?)\s+(\d+)%\s+(\S+)\s+(\S+)\s+"
        r"\(xfr#(\d+),\s*(ir-chk|to-chk)=(\d+)/(\d+)\)"
    )
    for line in re.split(r"[\r\n]+", text):
        match = pattern.search(line)
        if match:
            progress = {
                "bytes_display": match.group(1),
                "percent": int(match.group(2)),
                "rate": match.group(3),
                "eta": match.group(4),
                "files_transferred": int(match.group(5)),
                "check_kind": match.group(6),
                "checks_remaining": int(match.group(7)),
                "checks_total": int(match.group(8)),
                "percentage_provisional": match.group(6) == "ir-chk",
            }

current_path = None
source = state.get("source") or ""
if status == "running" and pid and source.startswith("/"):
    source_root = pathlib.Path(source.rstrip("/") or "/")
    if source_root.is_file():
        source_root = source_root.parent
    fd_root = pathlib.Path(f"/proc/{pid}/fd")
    try:
        for descriptor in fd_root.iterdir():
            try:
                candidate = descriptor.resolve(strict=True)
                candidate.relative_to(source_root.resolve(strict=True))
            except (FileNotFoundError, PermissionError, RuntimeError, ValueError):
                continue
            if candidate.is_file():
                current_path = str(candidate)
                break
    except (FileNotFoundError, PermissionError):
        pass

started = state.get("started_epoch") or int(time.time())
ended = state.get("finished_epoch") or int(time.time())
result = dict(state)
result["status"] = status
result["elapsed_seconds"] = max(0, ended - started)
result["progress"] = progress
result["current_path"] = current_path

if output == "json":
    print(json.dumps(result, indent=2, sort_keys=True))
else:
    print(f"job: {result['job']}")
    print(f"status: {status}")
    print(f"operation: {result['operation']}")
    print(f"elapsed: {result['elapsed_seconds']}s")
    if progress:
        qualifier = "provisional" if progress["percentage_provisional"] else "stable"
        print(f"progress: {progress['percent']}% ({qualifier}) / {progress['bytes_display']}")
        print(f"rate: {progress['rate']} / eta: {progress['eta']}")
        print(f"files transferred: {progress['files_transferred']}")
        print(f"remaining checks: {progress['checks_remaining']}/{progress['checks_total']} ({progress['check_kind']})")
    else:
        print("progress: waiting for rsync progress output")
    print(f"current file: {current_path or 'scanning or between files'}")
    print(f"log: {result['log_path']}")
    if result.get("exit_code") is not None:
        print(f"exit code: {result['exit_code']}")
PY
}

watch.job() {
  local job="$1" state
  validate.job.name "${job}"
  while true; do
    printf '\033[H\033[2J'
    status.job "${job}" text
    state="$(python3 - "$(job.state.path "${job}")" <<'PY'
import json, pathlib, sys, time
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
status = data.get("status", "unknown")
pid = data.get("rsync_pid")
queued_grace = status == "queued" and int(time.time()) - (data.get("started_epoch") or 0) <= 15
if status in {"queued", "running"} and not queued_grace \
        and (not pid or not pathlib.Path(f"/proc/{pid}").exists()):
    status = "stale"
print(status)
PY
)"
    [[ "${state}" == queued || "${state}" == running ]] || return 0
    sleep 2
  done
}

follow.job.log() {
  local job="$1" log_path
  validate.job.name "${job}"
  log_path="$(job.log.path "${job}")"
  [[ -f "${log_path}" ]] || die "No log exists for job ${job}."
  python3 -u - "${log_path}" <<'PY'
import pathlib, sys, time

path = pathlib.Path(sys.argv[1])
with path.open("r", encoding="utf-8", errors="replace") as handle:
    while True:
        chunk = handle.read(8192)
        if chunk:
            sys.stdout.write(chunk.replace("\r", "\n"))
            sys.stdout.flush()
        else:
            time.sleep(0.5)
PY
}

list.jobs() {
  prepare.job.directories
  python3 - "${JOB_STATE_DIR}" <<'PY'
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
rows = []
for path in sorted(root.glob("*.json")):
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        continue
    rows.append((data.get("job", path.stem), data.get("status", "unknown"),
                 data.get("started_at") or "-", data.get("destination") or "-"))
if not rows:
    print("No managed transfer jobs.")
else:
    print("JOB\tSTATUS\tSTARTED\tDESTINATION")
    for row in rows:
        print("\t".join(row))
PY
}

case "${ACTION}" in
  push|pull|verify-push|verify-pull|backup-push|backup-pull|verify-backup-push|verify-backup-pull)
    (($# == 3)) || usage
    require.runtime
    run.transfer "${ACTION}" "$2" "$3"
    ;;
  start-backup-push)
    (($# == 4)) || usage
    start.job backup-push "$2" "$3" "$4"
    ;;
  start-backup-pull)
    (($# == 4)) || usage
    start.job backup-pull "$2" "$3" "$4"
    ;;
  status)
    (($# == 2 || $# == 4)) || usage
    if (($# == 4)); then [[ "$3" == --output ]] || usage; status.job "$2" "$4"; else status.job "$2" text; fi
    ;;
  watch)
    (($# == 2)) || usage
    watch.job "$2"
    ;;
  log)
    (($# == 2)) || usage
    follow.job.log "$2"
    ;;
  list)
    (($# == 1)) || usage
    list.jobs
    ;;
  __run-job)
    (($# == 8)) || usage
    run.job "$2" "$3" "$4" "$5" "$6" "$7" "$8"
    ;;
  *) usage ;;
esac
