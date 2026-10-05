#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROXMOX_SAMBA_SOURCE_ONLY=1
export PROXMOX_SAMBA_INTERACTIVE=0
# shellcheck source=setup/lxc/samba.sh
source "${ROOT}/setup/lxc/samba.sh"

fail() {
  printf '[samba_credential_policy_test][error] %s\n' "$*" >&2
  exit 1
}

assert.equal() {
  local expected="$1" actual="$2" label="$3"
  [[ "${actual}" == "${expected}" ]] \
    || fail "${label}: expected=${expected} actual=${actual}"
}

reset.fixture() {
  CONTAINER_HOSTNAME="fixture-nas"
  FEATURE_INTERACTIVE=0
  OPEN_TTY=0
  PROXMOX_SAMBA_CREDENTIAL_MODE=""
  PROXMOX_SAMBA_AUTH_USER=""
  PROXMOX_SAMBA_AUTH_PASSWORD=""
  PROXMOX_SAMBA_ALLOW_HOSTNAME_PASSWORD=0
}

reset.fixture
FEATURE_MODE=preflight
select.samba.credentials
assert.equal hostname "${PROXMOX_SAMBA_CREDENTIAL_MODE}" 'default preflight credential mode'
assert.equal fixture-nas "${PROXMOX_SAMBA_AUTH_USER}" 'hostname-derived preflight username'
assert.equal '' "${PROXMOX_SAMBA_AUTH_PASSWORD}" 'preflight password remains empty'

reset.fixture
FEATURE_MODE=apply
select.samba.credentials
assert.equal hostname "${PROXMOX_SAMBA_CREDENTIAL_MODE}" 'default apply credential mode'
assert.equal fixture-nas "${PROXMOX_SAMBA_AUTH_USER}" 'hostname-derived apply username'
assert.equal fixture-nas "${PROXMOX_SAMBA_AUTH_PASSWORD}" 'hostname-derived apply password'

reset.fixture
FEATURE_MODE=apply
PROXMOX_SAMBA_CREDENTIAL_MODE=custom
PROXMOX_SAMBA_AUTH_USER=operator
PROXMOX_SAMBA_AUTH_PASSWORD='fixture-secret'
select.samba.credentials
assert.equal custom "${PROXMOX_SAMBA_CREDENTIAL_MODE}" 'custom apply credential mode'
assert.equal operator "${PROXMOX_SAMBA_AUTH_USER}" 'custom apply username'
assert.equal fixture-secret "${PROXMOX_SAMBA_AUTH_PASSWORD}" 'custom apply password'

if (
  reset.fixture
  FEATURE_MODE=apply
  PROXMOX_SAMBA_CREDENTIAL_MODE=custom
  PROXMOX_SAMBA_AUTH_USER='Invalid User'
  PROXMOX_SAMBA_AUTH_PASSWORD='fixture-secret'
  select.samba.credentials
) >/dev/null 2>&1; then
  fail 'invalid custom username was accepted'
fi

if (
  reset.fixture
  FEATURE_MODE=apply
  PROXMOX_SAMBA_CREDENTIAL_MODE=unsupported
  select.samba.credentials
) >/dev/null 2>&1; then
  fail 'unsupported credential mode was accepted'
fi

TEST_ROOT="$(mktemp -d)"
trap 'remove.samba.secret.file; rm -rf "${TEST_ROOT}"' EXIT
SAMBA_EXTRA_VARS_PATH="${TEST_ROOT}/samba.extra-vars.yml"
printf 'password: fixture-secret\n' > "${SAMBA_EXTRA_VARS_PATH}"
remove.samba.secret.file
[[ ! -e "${SAMBA_EXTRA_VARS_PATH}" ]] || fail 'temporary secret file was retained'

SAMBA_EXTRA_VARS_PATH="${TEST_ROOT}/rendered.extra-vars.yml"
FEATURE_MODE=preflight
FACTS_DIR="/etc/ansible/proxmox/facts"
CONTAINER_FACTS_PATH="${FACTS_DIR}/container.yml"
SAMBA_FACTS_PATH="${FACTS_DIR}/samba.yml"
SAMBA_MOUNTS_TSV="${FACTS_DIR}/samba.mounts.tsv"
SAMBA_SELECTION_PATH="${FACTS_DIR}/samba.selection.yml"
PROXMOX_SAMBA_DATA_INTERFACE=eth1
PROXMOX_SAMBA_EGRESS_INTERFACE=eth0
PROXMOX_SAMBA_DNS_SERVERS='10.0.0.1'
PROXMOX_SAMBA_CREDENTIAL_MODE=hostname
PROXMOX_SAMBA_AUTH_USER=fixture-nas
PROXMOX_SAMBA_AUTH_PASSWORD=''
PROXMOX_SAMBA_ALLOW_USERS_OVERRIDE=false
ALLOW_SUBNET_LIST=('10.10.0.0/24')
PROXMOX_SAMBA_ALLOW_USERS_SELECTED=(root app agent)
PROXMOX_SAMBA_ALLOW_USERS_CLI=()
SELECTED_SHARES=('/media/ARCHIVE')
MOUNT_PATH=('/media/ARCHIVE')
MOUNT_SHARE_NAME=('ARCHIVE')
MOUNT_READABLE=('yes')
MOUNT_WRITABLE=('yes')
MOUNT_XATTR=('yes')
write.samba.extra.vars.file

python3 - "${SAMBA_EXTRA_VARS_PATH}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    payload = yaml.safe_load(stream)

shares = payload["proxmox_samba"]["shares"]["explicit"]
assert len(shares) == 1
assert shares[0]["path"] == "/media/ARCHIVE"
assert shares[0]["name"] == "ARCHIVE"
assert shares[0]["writable"] is True
assert "shares" not in payload
assert payload["proxmox_samba_access_users_runner"] == ["root", "app", "agent"]
PY

printf '[samba_credential_policy_test][ok] hostname/custom credentials, secret cleanup, and production YAML rendering\n'
