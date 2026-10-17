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
mkdir -p "${bind_root}/chosen" "${fixture_dir}/lxc"
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
SERVICE_USER='share-user'
SERVICE_GROUP='share-group'
TRANSFER_USER='transfer-user'
RECONCILE=1
INTERACTIVE=0
LXC_CONFIG_DIR="${fixture_dir}/lxc"

discover.selection
[[ "${MOUNT_SLOT}" == mp0 && "${SELECTED_SOURCE}" == "${bind_root}" \
  && "${SELECTED_PATH}" == "${bind_root}/chosen" \
  && "${SELECTED_CONTAINER_PATH}" == /archive/chosen ]] \
  || fail 'production bind-mount path selection returned the wrong destination'
resolve.reconciliation.identities
[[ "${SERVICE_UID}" == 2002 && "${SERVICE_GID}" == 2000 && "${TRANSFER_UID}" == 2003 ]] \
  || fail 'production identity discovery returned the wrong IDs'
[[ "$(map.container.id u "${SERVICE_UID}")" == 202002 ]] \
  || fail 'production UID map resolver returned the wrong host UID'
[[ "$(map.container.id g "${SERVICE_GID}")" == 302000 ]] \
  || fail 'production GID map resolver returned the wrong host GID'
refuse.active.transfer
FAKE_ACTIVE_RSYNC=1
if (refuse.active.transfer); then fail 'active rsync was accepted'; fi
FAKE_ACTIVE_RSYNC=0
ok 'production destination, identity, ID-map, and active-transfer gates'

CONTAINER_PATH='/archive/linked'
if (select.reconciliation.path "mp0|${bind_root}|/archive"); then
  fail 'symlinked destination was accepted'
fi
CONTAINER_PATH='/archive-other/chosen'
if (select.reconciliation.path "mp0|${bind_root}|/archive"); then
  fail 'container path outside the bind target was accepted'
fi
ok 'production path containment and symlink rejection'

if grep -Eq '/etc/fstab|^[[:space:]]*(mount|umount)[[:space:]]|pct (start|stop|shutdown|reboot)' \
  "${ROOT}/setup/lxc/storage.sh"; then
  fail 'storage reconciliation contains persistent mount, mount lifecycle, or container restart commands'
fi
ok 'reconciliation leaves mount and container lifecycle to the operator'
