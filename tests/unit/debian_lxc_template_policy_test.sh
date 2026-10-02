#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROXMOX_LXC_DEBIAN_SOURCE_ONLY=1
# shellcheck source=../../setup/lxc/debian.sh
source "${ROOT}/setup/lxc/debian.sh"

fail() {
  printf '[debian.lxc.template.test][error] %s\n' "$*" >&2
  exit 1
}

assert.eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "${actual}" == "${expected}" ]] \
    || fail "${label}: expected=${expected}, actual=${actual}"
}

PVEAM_UPDATE_RESULT=0
PVEAM_FIXTURE=""
PVEAM_LIVE_FIXTURE=$'Section Template\nsystem debian-12-standard_12.12-1_amd64.tar.zst\nsystem debian-13-standard_13.1-2_amd64.tar.zst\nsystem debian-13-standard_13.6-1_amd64.tar.gz\nsystem debian-13-standard_13.6-1_amd64.tar.zst\nsystem debian-13-standard_13.6-1.1_amd64.tar.zst\nsystem debian-13-standard_13.7-1_arm64.tar.zst\nsystem ../debian-13-standard_99.0-1_amd64.tar.zst\nsystem debian-14-standard_14.0-1_amd64.tar.zst'

pveam() {
  case "${1:-}" in
    update)
      if ((PVEAM_UPDATE_RESULT == 0)); then
        printf 'update successful\n'
        return 0
      fi
      printf 'simulated catalog refresh failure\n' >&2
      return 1
      ;;
    available)
      printf '%s\n' "${PVEAM_FIXTURE}"
      ;;
    *)
      return 1
      ;;
  esac
}

case.regex.contract() {
  template.name.is.valid 'debian-13-standard_13.6-1_amd64.tar.zst' \
    || fail 'current Trixie filename was rejected'
  template.name.is.valid 'debian-13-standard_13.6-1.1_amd64.tar.xz' \
    || fail 'point-revision filename was rejected'
  template.name.is.valid 'debian-14-standard_14.0-1_amd64.tar.gz' \
    || fail 'future numeric Debian filename was not discoverable'
  ! template.name.is.valid 'debian-13-standard_13.6-1_arm64.tar.zst' \
    || fail 'arm64 filename was accepted by the amd64 runner'
  ! template.name.is.valid '../debian-13-standard_13.6-1_amd64.tar.zst' \
    || fail 'path traversal filename was accepted'
  ! template.name.is.valid 'debian-13-standard_latest_amd64.tar.zst' \
    || fail 'unversioned filename was accepted'
}

case.latest.live.catalog() {
  PVEAM_UPDATE_RESULT=0
  PVEAM_FIXTURE="${PVEAM_LIVE_FIXTURE}"

  discover.remote.templates || fail 'valid live catalog was rejected'
  assert.eq true "${PVEAM_CATALOG_READY}" 'live catalog readiness'
  assert.eq 'debian-12-standard_12.12-1_amd64.tar.zst' \
    "$(template.remote.latest.from.major 12)" 'Debian 12 latest selection'
  assert.eq 'debian-13-standard_13.6-1.1_amd64.tar.zst' \
    "$(template.remote.latest.from.major 13)" 'Debian 13 latest selection'
  ! template.remote.latest.from.major 14 >/dev/null 2>&1 \
    || fail 'unsupported future Debian major was selectable'
}

case.headerless.catalog() {
  PVEAM_UPDATE_RESULT=0
  PVEAM_FIXTURE='system debian-13-standard_13.6-1_amd64.tar.zst'
  discover.remote.templates || fail 'headerless pveam catalog was rejected'
  assert.eq 'debian-13-standard_13.6-1_amd64.tar.zst' \
    "$(template.remote.latest.from.major 13)" 'first headerless catalog row'

  PVEAM_FIXTURE="${PVEAM_LIVE_FIXTURE}"
  discover.remote.templates || fail 'live fixture restore failed'
}

case.noninteractive.selection() {
  DEFAULT_TEMPLATE=""
  DEFAULT_TEMPLATE_MAJOR=13
  TEMPLATE_LOCAL=('debian-13-standard_13.1-2_amd64.tar.zst')
  select.template.noninteractive
  assert.eq 'debian-13-standard_13.6-1.1_amd64.tar.zst' \
    "${SELECTED_TEMPLATE_NAME}" 'stale local template upgrade selection'
  assert.eq pveam "${SELECTED_TEMPLATE_DOWNLOAD_METHOD}" 'stale local download method'
  assert.eq latest "${SELECTED_TEMPLATE_STATUS}" 'latest template status'

  TEMPLATE_LOCAL=('debian-13-standard_13.6-1.1_amd64.tar.zst')
  select.template.noninteractive
  assert.eq local "${SELECTED_TEMPLATE_DOWNLOAD_METHOD}" 'matching local cache reuse'
}

case.catalog.failure() {
  PVEAM_UPDATE_RESULT=1
  PVEAM_FIXTURE='system debian-13-standard_13.6-1_amd64.tar.zst'
  ! discover.remote.templates || fail 'failed pveam refresh was accepted'
  assert.eq false "${PVEAM_CATALOG_READY}" 'failed catalog readiness'
  [[ "${PVEAM_CATALOG_ERROR}" == pveam\ update\ failed:* ]] \
    || fail 'failed catalog diagnostic was not preserved'

  DEFAULT_TEMPLATE='debian-13-standard_13.6-1_amd64.tar.zst'
  DEFAULT_TEMPLATE_MAJOR=""
  TEMPLATE_LOCAL=("${DEFAULT_TEMPLATE}")
  select.template.noninteractive
  assert.eq local "${SELECTED_TEMPLATE_DOWNLOAD_METHOD}" 'exact local fallback on refresh failure'

  TEMPLATE_LOCAL=()
  ! (select.template.noninteractive >/dev/null 2>&1) \
    || fail 'remote selection continued after catalog refresh failure'
}

case.regex.contract
case.latest.live.catalog
case.headerless.catalog
case.noninteractive.selection
case.catalog.failure

printf '[debian.lxc.template.test][ok] dynamic template policy passed\n'
