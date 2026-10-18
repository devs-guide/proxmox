#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf '[lxc_storage_reconcile_policy_test][error] %s\n' "$*" >&2; exit 1; }
ok() { printf '[lxc_storage_reconcile_policy_test][ok] %s\n' "$*"; }

export PROXMOX_LXC_STORAGE_SOURCE_ONLY=1
# shellcheck source=setup/lxc/storage.sh
source "${ROOT}/setup/lxc/storage.sh"

fixture_dir="$(mktemp -d)"
trap 'rm -rf "${fixture_dir}"' EXIT
bind_root="${fixture_dir}/archive"
mkdir -p "${bind_root}/chosen/private" "${fixture_dir}/lxc"
ln -s "${bind_root}/chosen" "${bind_root}/linked"
cat > "${fixture_dir}/lxc/101.conf" <<'EOF'
lxc.idmap: u 0 200000 65536
lxc.idmap: g 0 300000 65536
EOF

FAKE_ACTIVE_RSYNC=0
pct() {
  case "${1:-}" in
    list)
      printf 'VMID Status Lock Name\n101 running - fixture\n'
      ;;
    config)
      printf 'unprivileged: 1\nmp0: %s,mp=/archive,backup=0\n' "${bind_root}"
      ;;
    status)
      printf 'status: running\n'
      ;;
    exec)
      shift 3
      case "${1:-} ${2:-} ${3:-}" in
        'getent passwd share-user') printf 'share-user:x:2002:2000::/nonexistent:/usr/sbin/nologin\n' ;;
        'getent group share-group') printf 'share-group:x:2000:\n' ;;
        'getent passwd transfer-user') printf 'transfer-user:x:2003:2003::/nonexistent:/usr/sbin/nologin\n' ;;
        'pgrep -x rsync') ((FAKE_ACTIVE_RSYNC == 1)) ;;
        '/bin/sh -c command -v pgrep >/dev/null && command -v setpriv >/dev/null') return 0 ;;
        *) fail "unexpected pct exec fixture call: $*" ;;
      esac
      ;;
    *) fail "unexpected pct fixture call: $*" ;;
  esac
}
mountpoint() { [[ "${3:-}" == "${bind_root}" ]]; }

CTID=101
MOUNT_SLOT=''
CONTAINER_PATH='/archive/chosen'
EXCLUDE_CONTAINER_PATH='/archive/chosen/private'
SERVICE_USER='share-user'
SERVICE_GROUP='share-group'
TRANSFER_USER='transfer-user'
RECONCILE=1
INTERACTIVE=0
LXC_CONFIG_DIR="${fixture_dir}/lxc"

discover.selection
[[ "${MOUNT_SLOT}" == mp0 && "${SELECTED_SOURCE}" == "${bind_root}" \
  && "${SELECTED_PATH}" == "${bind_root}/chosen" \
  && "${SELECTED_CONTAINER_PATH}" == /archive/chosen \
  && "${EXCLUDED_PATH}" == "${bind_root}/chosen/private" ]] \
  || fail 'production bind-mount path selection returned the wrong destination'
resolve.reconciliation.identities
[[ "${SERVICE_UID}" == 2002 && "${SERVICE_GID}" == 2000 \
  && "${TRANSFER_UID}" == 2003 && "${TRANSFER_GID}" == 2003 ]] \
  || fail 'production identity discovery returned the wrong IDs'
[[ "$(map.container.id u "${SERVICE_UID}")" == 202002 ]] \
  || fail 'production UID map resolver returned the wrong host UID'
[[ "$(map.container.id g "${SERVICE_GID}")" == 302000 ]] \
  || fail 'production GID map resolver returned the wrong host GID'
[[ "$(map.container.id u "${TRANSFER_UID}")" == 202003 \
  && "$(map.container.id g "${TRANSFER_GID}")" == 302003 ]] \
  || fail 'production transfer identity map resolver returned the wrong host IDs'
[[ "$(map.container.id u 0)" == 200000 && "$(map.container.id g 0)" == 300000 ]] \
  || fail 'production container-root map resolver returned the wrong host IDs'
refuse.active.transfer
FAKE_ACTIVE_RSYNC=1
if (refuse.active.transfer); then fail 'active rsync was accepted'; fi
FAKE_ACTIVE_RSYNC=0
ok 'production destination, identity, ID-map, and active-transfer gates'

EXCLUDE_CONTAINER_PATH=''
EXCLUDED_PATH=''
CONTAINER_PATH='/archive/linked'
if (select.reconciliation.path "mp0|${bind_root}|/archive"); then
  fail 'symlinked destination was accepted'
fi
CONTAINER_PATH='/archive-other/chosen'
if (select.reconciliation.path "mp0|${bind_root}|/archive"); then
  fail 'container path outside the bind target was accepted'
fi
ok 'production path containment and symlink rejection'

operation_log="${fixture_dir}/transfer-destination.log"
chown() { printf 'chown %s\n' "$*" >> "${operation_log}"; }
setfacl() { printf 'setfacl %s\n' "$*" >> "${operation_log}"; }
find() { fail 'transfer destination preparation attempted recursive traversal'; }
SELECTED_PATH="${bind_root}/chosen"
apply.transfer.destination 202002 302000 202003 302003 200000 300000
grep -Fqx "chown --no-dereference 202003:302003 ${SELECTED_PATH}" "${operation_log}" \
  || fail 'transfer destination preparation did not assign only the selected root to the mapped transfer identity'
grep -Fq -- '--no-dereference' "${operation_log}" \
  || fail 'transfer destination ownership does not refuse symlink traversal'
grep -Fq 'u:202002:rwx,g:302000:rwx' "${operation_log}" \
  || fail 'transfer destination preparation omitted the service identity ACL'
grep -Fq 'u:202003:rwx,g:302003:rwx' "${operation_log}" \
  || fail 'transfer destination preparation omitted the transfer identity ACL'
grep -Fq 'u:200000:rwx,g:300000:rwx' "${operation_log}" \
  || fail 'transfer destination preparation omitted the mapped container-root ACL'
unset -f chown setfacl find
ok 'transfer destination preparation is root-only and identity-derived'

EXCLUDE_CONTAINER_PATH='/archive/chosen/private'
EXCLUDED_PATH="${bind_root}/chosen/private"
printf 'fixture\n' > "${bind_root}/chosen/file.txt"
mkdir -p "${bind_root}/chosen/nested"
printf 'private\n' > "${bind_root}/chosen/private/private.txt"
owner_before="$(stat -c '%u:%g' "${bind_root}/chosen")"
apply.reconciliation 202002 302000 202003 302003 200000 300000
owner_after="$(stat -c '%u:%g' "${bind_root}/chosen")"
[[ "${owner_before}" == "${owner_after}" ]] || fail 'recursive reconciliation changed destination ownership'
acl="$(getfacl -ncp "${bind_root}/chosen")"
for entry in \
  'user:202002:rwx' 'group:302000:rwx' \
  'user:202003:rwx' 'group:302003:rwx' \
  'user:200000:rwx' 'group:300000:rwx' \
  'default:user:202002:rwx' 'default:user:202003:rwx' 'default:user:200000:rwx'; do
  grep -Fxq "${entry}" <<< "${acl}" || fail "recursive reconciliation omitted ${entry}"
done
private_acl="$(getfacl -ncp "${bind_root}/chosen/private")"
! grep -Fq 'user:202002:rwx' <<< "${private_acl}" \
  || fail 'operator-excluded subtree received a reconciliation ACL'
ok 'recursive reconciliation grants all identities while pruning the selected exclusion'

owner_uid="$(id -u)"
owner_dir="${bind_root}/chosen/owner-restricted"
owner_plain="${bind_root}/chosen/owner-plain"
owner_executable="${bind_root}/chosen/owner-executable"
mkdir -p "${owner_dir}"
: > "${owner_plain}"
: > "${owner_executable}"
chmod 100 "${owner_dir}" "${owner_executable}"
chmod 000 "${owner_plain}"
apply.identity.owner.access "${owner_uid}" "${owner_uid}" "${owner_uid}"
getfacl -ncp "${owner_dir}" | grep -Fxq 'user::rwx' \
  || fail 'identity-owned directory did not receive owner read/write/traverse access'
getfacl -ncp "${owner_plain}" | grep -Fxq 'user::rw-' \
  || fail 'identity-owned non-executable file did not retain a non-executable owner entry'
getfacl -ncp "${owner_executable}" | grep -Fxq 'user::rwx' \
  || fail 'identity-owned executable file did not retain its owner execute bit'
ok 'identity-owner ACL repair preserves executable state while adding required access'

[[ "$(count.missing.default.acls 202002 302000 202003 302003 200000 300000)" == 0 ]] \
  || fail 'batched verifier rejected complete inherited ACLs'
setfacl -x d:u:202003 "${bind_root}/chosen/nested"
[[ "$(count.missing.default.acls 202002 302000 202003 302003 200000 300000)" == 1 ]] \
  || fail 'batched verifier did not count a directory with an incomplete inherited ACL'
ok 'batched inherited-ACL verification counts directory records accurately'

if grep -Eq '/etc/fstab|^[[:space:]]*(mount|umount)[[:space:]]|pct (start|stop|shutdown|reboot)' \
  "${ROOT}/setup/lxc/storage.sh"; then
  fail 'storage reconciliation contains persistent mount, mount lifecycle, or container restart commands'
fi
ok 'reconciliation leaves mount and container lifecycle to the operator'

grep -Fq 'env -u BASH_ENV -u ENV' "${ROOT}/setup/lxc/storage.sh" \
  || fail 'unprivileged storage probes inherit privileged shell startup hooks'
grep -Fq 'cd /' "${ROOT}/setup/lxc/storage.sh" \
  || fail 'unprivileged storage probes do not leave the privileged working directory'
ok 'unprivileged probes clear root shell hooks and working-directory inheritance'
