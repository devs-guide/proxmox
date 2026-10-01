#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${ROOT}/setup/storage/zfs.sh"
CONFIG_RUNNER="${ROOT}/setup/storage/zpool.config.sh"
HELPER="${ROOT}/cli/storage/zfs.pool.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { printf '[validate.storage.zfs][error] %s\n' "$*" >&2; exit 1; }
ok() { printf '[validate.storage.zfs][ok] %s\n' "$*"; }
expect_failure() {
  if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi
}

for path in "${RUNNER}" "${CONFIG_RUNNER}" "${HELPER}"; do
  [[ -f "${path}" ]] || fail "missing implementation: ${path#${ROOT}/}"
done
bash -n "${RUNNER}" "${CONFIG_RUNNER}" "${HELPER}"
ok "shell syntax"

mkdir -p "${TMP}/bin" "${TMP}/work" "${TMP}/mount" "${TMP}/locks" "${TMP}/state"

cat > "${TMP}/bin/zpool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  create)
    printf '%s\n' "$*" >> "${ZFS_TEST_COMMAND_LOG}"
    ;;
  import)
    exit 0
    ;;
  list)
    printf '%s\n' "$(jq -r '.pool.name' "${ZFS_TEST_CONFIG}")"
    ;;
  status)
    config="${ZFS_TEST_STATUS_CONFIG:-${ZFS_TEST_CONFIG}}"
    pool="$(jq -r '.pool.name' "${config}")"
    printf '  pool: %s\n state: ONLINE\nconfig:\n\n        NAME STATE\n        %s ONLINE\n' "${pool}" "${pool}"
    count="$(jq '.vdevs|length' "${config}")"
    for ((index=0; index<count; index++)); do
      type="$(jq -r --argjson index "${index}" '.vdevs[$index].type' "${config}")"
      printf '          %s-%s ONLINE\n' "${type}" "${index}"
      jq -r --argjson index "${index}" '.vdevs[$index].devices[].path | "            \(.) ONLINE"' "${config}"
    done
    ;;
  get)
    property="${5:-}"
    jq -r --arg property "${property}" '.pool.properties[$property] // empty' "${ZFS_TEST_CONFIG}"
    ;;
  *) exit 0 ;;
esac
EOF

cat > "${TMP}/bin/zfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  create)
    printf '%s\n' "$*" >> "${ZFS_TEST_COMMAND_LOG}"
    ;;
  list)
    if [[ "${2:-}" == "-H" && "${3:-}" == "-o" && "${4:-}" == "name" ]]; then
      printf '%s\n' "${5:-}"
    else
      jq -r '.pool.name, .datasets[].name' "${ZFS_TEST_CONFIG}"
    fi
    ;;
  get)
    property="${5:-}"
    dataset="${6:-}"
    pool="$(jq -r '.pool.name' "${ZFS_TEST_CONFIG}")"
    if [[ "${property}" == "mounted" ]]; then
      canmount="$(jq -r --arg dataset "${dataset}" '.datasets[]|select(.name==$dataset)|.properties.canmount' "${ZFS_TEST_CONFIG}")"
      [[ "${canmount}" == "on" ]] && printf 'yes\n' || printf 'no\n'
    elif [[ "${dataset}" == "${pool}" ]]; then
      jq -r --arg property "${property}" '.pool.filesystem_properties[$property] // empty' "${ZFS_TEST_CONFIG}"
    elif [[ "${property}" == "mountpoint" ]]; then
      jq -r --arg dataset "${dataset}" '.datasets[]|select(.name==$dataset)|.mountpoint' "${ZFS_TEST_CONFIG}"
    else
      jq -r --arg dataset "${dataset}" --arg property "${property}" '.datasets[]|select(.name==$dataset)|.properties[$property] // empty' "${ZFS_TEST_CONFIG}"
    fi
    ;;
  *) exit 0 ;;
esac
EOF

cat > "${TMP}/bin/wipefs" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ZFS_TEST_COMMAND_LOG}"
EOF
chmod 0755 "${TMP}/bin/zpool" "${TMP}/bin/zfs" "${TMP}/bin/wipefs"

jq -n '{schema_version:1,disks:[range(1;13) as $i | {
  kernel:("sd"+($i|tostring)),path:("/dev/sd"+($i|tostring)),
  stable_path:("/dev/disk/by-id/wwn-0x5000"+(100000000000+$i|tostring)),
  wwn:("0x5000"+(100000000000+$i|tostring)),serial:("SER"+($i|tostring)),
  model:"TEST",vendor:"TEST",transport:(if $i<=10 then "sas" else "sata" end),media:"hdd",
  size_bytes:(if $i==12 then 4000000000000 else 6000000000000 end),rotational:true,
  logical_sector_bytes:512,physical_sector_bytes:4096,smart_health:"passed",
  hba:(if $i%2==0 then "host2" else "host1" end),enclosure:"enc0",slot:($i|tostring),
  fault_domain:(if $i%2==0 then "host2:enc0" else "host1:enc0" end),whole_disk:true,
  signatures:[],reasons:[],warnings:[],eligible:true
}]}' > "${TMP}/inventory.json"

export PROXMOX_ZFS_TEST_MODE=1
export ZFS_TEST_COMMAND_LOG="${TMP}/commands.log"
export PROXMOX_ZFS_LOCK_ROOT="${TMP}/locks"
export PROXMOX_ZFS_STATE_ROOT="${TMP}/state"
export PATH="${TMP}/bin:${PATH}"

size_decimal="$(bash -c 'source "$1"; zfs.size.to.bytes 6TB' _ "${HELPER}")"
size_binary="$(bash -c 'source "$1"; zfs.size.to.bytes 5.5TiB' _ "${HELPER}")"
[[ "${size_decimal}" == 6000000000000 ]] || fail "6TB was not parsed as decimal bytes"
[[ "${size_binary}" == 6047313952768 ]] || fail "5.5TiB was not parsed as binary bytes"
expect_failure bash -c 'source "$1"; zfs.size.to.bytes 5.5T' _ "${HELPER}"
ok "explicit decimal and binary size parsing"

INTERACTIVE_CANDIDATES="$(jq -c '.disks[0:4]' "${TMP}/inventory.json")"
interactive_selection="$(CANDIDATES="${INTERACTIVE_CANDIDATES}" HELPER="${HELPER}" bash -c '
  source "${HELPER}"
  zfs.prompt() {
    case "$1" in
      *serial=SER1*) printf "y\n" ;;
      *serial=SER2*) printf "n\n" ;;
      *) printf "all\n" ;;
    esac
  }
  zfs.config.choose.interactive "${CANDIDATES}"
')"
[[ "$(jq 'length' <<< "${interactive_selection}")" -eq 3 ]] || fail "y/n/all prompt semantics"
none_selection="$(CANDIDATES="${INTERACTIVE_CANDIDATES}" HELPER="${HELPER}" bash -c '
  source "${HELPER}"
  zfs.prompt() { printf "none\n"; }
  zfs.config.choose.interactive "${CANDIDATES}"
')"
[[ "$(jq 'length' <<< "${none_selection}")" -eq 0 ]] || fail "none prompt semantics"
ok "interactive y/n/all/none selection"

jq '.disks=.disks[0:4]' "${TMP}/inventory.json" > "${TMP}/four-sas.json"
CONFIG="${TMP}/work/zpool.config"
(
  cd "${TMP}/work"
  "${RUNNER}" --inventory-file "${TMP}/four-sas.json" --type sas --media hdd --size 6TB \
    --all-matches --non-interactive --vdev-type raidz2 --vdev-count 1 \
    --mountpoint "${TMP}/mount" >/dev/null
)
[[ "$(stat -c '%a' "${CONFIG}" 2>/dev/null || stat -f '%Lp' "${CONFIG}")" == 600 ]] || fail "zpool.config mode is not 0600"
jq -e '
  .selection.filters.size_bytes=={minimum_bytes:5940000000000,maximum_bytes:6060000000000} and
  (.vdevs|length)==1 and .vdevs[0].type=="raidz2" and (.vdevs[0].devices|length)==4 and
  all(.vdevs[].devices[];.expected_transport=="sas" and .expected_size_bytes==6000000000000 and .logical_sector_bytes==512 and .physical_sector_bytes==4096)
' "${CONFIG}" >/dev/null || fail "general configuration contract"
"${RUNNER}" validate-config --config "${CONFIG}" >/dev/null
ok "flag-first configure writes editable dynamic topology"

mkdir -p "${TMP}/standalone" "${TMP}/standalone-bin"
cp "${RUNNER}" "${TMP}/standalone/zfs.sh"
cat > "${TMP}/standalone-bin/wget" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-qO" && -n "${2:-}" && -n "${3:-}" ]]
cp "${ZFS_TEST_HELPER_SOURCE}" "${2}"
EOF
chmod 0755 "${TMP}/standalone/zfs.sh" "${TMP}/standalone-bin/wget"
ZFS_TEST_HELPER_SOURCE="${HELPER}" \
PROXMOX_ZFS_TEST_MODE=0 \
PROXMOX_ZFS_TMP_DIR="${TMP}/standalone-cache" \
PATH="${TMP}/standalone-bin:${PATH}" \
  "${TMP}/standalone/zfs.sh" validate-config --config "${CONFIG}" >/dev/null
expect_failure env \
  ZFS_TEST_HELPER_SOURCE="${HELPER}" \
  PROXMOX_ZFS_TEST_MODE=0 \
  PROXMOX_ZFS_TMP_DIR="${TMP}/stream-cache" \
  PATH="${TMP}/standalone-bin:${PATH}" \
  bash -s -- validate-config --config "${CONFIG}" < "${TMP}/standalone/zfs.sh"
ok "downloaded standalone runner preserves provenance while streamed mutation stays blocked"

export PROXMOX_ZFS_INVENTORY_FIXTURE="${TMP}/four-sas.json"
export ZFS_TEST_CONFIG="${CONFIG}"
"${RUNNER}" preflight --config "${CONFIG}" >/dev/null
"${RUNNER}" plan --config "${CONFIG}" --plan-file "${TMP}/zpool.plan" >/dev/null
PLAN="${TMP}/zpool.plan"
jq -e '
  .plan_kind=="create" and .requires_signature_wipe==false and
  (.configuration_source|endswith("/work/zpool.config")) and
  (.commands.zpool_create|index("-f")|not) and
  (.commands.zpool_create|index("ashift=12")!=null) and
  (.commands.zpool_create|index("autotrim=off")!=null) and
  (.commands.zpool_create|index("compression=lz4")!=null) and
  ([.commands.zpool_create[]|select(.=="raidz2")]|length)==1 and
  (.commands.dataset_creates[0]|index("canmount=on")!=null) and
  (.commands.dataset_creates[0]|index("dedup=off")!=null) and
  .capacity.raw_bytes==24000000000000 and .capacity.estimated_usable_bytes==12000000000000
' "${PLAN}" >/dev/null || fail "dynamic RAIDZ2 plan contract"
grep -Fq 'create -n' "${TMP}/commands.log" || fail "plan did not run zpool create -n"
cp "${CONFIG}" "${TMP}/config.saved"
printf '\n' >> "${CONFIG}"
expect_failure bash -c 'source "$1"; zfs.plan.revalidate "$2"' _ "${HELPER}" "${PLAN}"
mv "${TMP}/config.saved" "${CONFIG}"
"${RUNNER}" verify --config "${CONFIG}" >/dev/null
ok "dynamic planning, config invalidation, capacity estimate, dry-run, and verification"

for spec in 'mirror:6:3:2' 'raidz1:3:1:3' 'raidz3:5:1:5' 'raidz2:8:2:4'; do
  IFS=: read -r type count vdevs width <<< "${spec}"
  fixture="${TMP}/${type}-${count}.json"
  directory="${TMP}/${type}-${count}"
  mkdir -p "${directory}"
  jq --argjson count "${count}" '.disks=.disks[0:$count]' "${TMP}/inventory.json" > "${fixture}"
  (
    cd "${directory}"
    "${CONFIG_RUNNER}" --inventory-file "${fixture}" --type sas --all-matches --non-interactive \
      --vdev-type "${type}" --vdev-count "${vdevs}" >/dev/null
  )
  generated="${directory}/zpool.config"
  "${RUNNER}" validate-config --config "${generated}" >/dev/null
  jq -e --arg type "${type}" --argjson vdevs "${vdevs}" --argjson width "${width}" \
    '(.vdevs|length)==$vdevs and all(.vdevs[];.type==$type and (.devices|length)==$width)' "${generated}" >/dev/null || fail "topology ${spec}"
done
ok "mirror and RAIDZ1/2/3 layouts with configurable vdev counts"

for transport in sata scsi nvme usb; do
  fixture="${TMP}/filter-${transport}.json"
  directory="${TMP}/filter-${transport}"
  mkdir -p "${directory}"
  jq --arg transport "${transport}" '.disks=.disks[0:2]|.disks[]|=. + {transport:$transport,media:"ssd",rotational:false,size_bytes:4000000000000}' \
    "${TMP}/inventory.json" > "${fixture}"
  (
    cd "${directory}"
    "${CONFIG_RUNNER}" --inventory-file "${fixture}" --type "${transport}" --media ssd --size 4TB \
      --all-matches --non-interactive --vdev-type mirror --vdev-count 1 >/dev/null
  )
  jq -e --arg transport "${transport}" 'all(.vdevs[].devices[];.expected_transport==$transport and .expected_size_bytes==4000000000000)' \
    "${directory}/zpool.config" >/dev/null || fail "transport/media filter ${transport}"
done

jq '.disks=.disks[0:5]' "${TMP}/inventory.json" > "${TMP}/avoid.json"
mkdir -p "${TMP}/avoid-config"
(
  cd "${TMP}/avoid-config"
  "${CONFIG_RUNNER}" --inventory-file "${TMP}/avoid.json" --type sas --avoid SER5 \
    --all-matches --non-interactive --vdev-type raidz2 --vdev-count 1 >/dev/null
)
jq -e '([.vdevs[].devices[]]|length)==4 and ([.vdevs[].devices[].expected_serial]|index("SER5")|not)' \
  "${TMP}/avoid-config/zpool.config" >/dev/null || fail "avoid filter"

mkdir -p "${TMP}/explicit-config"
(
  cd "${TMP}/explicit-config"
  "${CONFIG_RUNNER}" --inventory-file "${TMP}/inventory.json" --type sas --non-interactive \
    --device SER1 --device SER2 --device SER3 --device SER4 \
    --vdev-type raidz2 --vdev-count 1 >/dev/null
)
jq -e '([.vdevs[].devices[].expected_serial])==["SER1","SER2","SER3","SER4"]' \
  "${TMP}/explicit-config/zpool.config" >/dev/null || fail "explicit device selection"

expect_failure bash -c 'cd "$1" && "$2" --inventory-file "$3" --type sas --all-matches --non-interactive --vdev-type raidz2 --vdev-count 2 --drives-per-vdev 4' \
  _ "${TMP}" "${CONFIG_RUNNER}" "${TMP}/inventory.json"
ok "transport, media, size, avoidance, exact-device, and excess-match filters"

TWO_VDEV_CONFIG="${TMP}/raidz2-8/zpool.config"
jq '(.vdevs[0].devices[0].path) as $a | (.vdevs[1].devices[0].path) as $b | .vdevs[0].devices[0].path=$b | .vdevs[1].devices[0].path=$a' \
  "${TWO_VDEV_CONFIG}" > "${TMP}/swapped-status.json"
ZFS_TEST_CONFIG="${TWO_VDEV_CONFIG}" ZFS_TEST_STATUS_CONFIG="${TMP}/swapped-status.json" \
  expect_failure bash -c 'source "$1"; zfs.verify.topology "$2"' _ "${HELPER}" "${TWO_VDEV_CONFIG}"
ok "post-create verification rejects cross-vdev membership drift"

cp "${CONFIG}" "${TMP}/invalid.json"
jq '.vdevs[0].devices=.vdevs[0].devices[0:3]' "${CONFIG}" > "${TMP}/invalid.json"
expect_failure "${RUNNER}" validate-config --config "${TMP}/invalid.json"
jq '.vdevs[0].devices[1].path=.vdevs[0].devices[0].path' "${CONFIG}" > "${TMP}/invalid.json"
expect_failure "${RUNNER}" validate-config --config "${TMP}/invalid.json"
jq '.vdevs[0].type="stripe"' "${CONFIG}" > "${TMP}/invalid.json"
expect_failure "${RUNNER}" validate-config --config "${TMP}/invalid.json"
ok "invalid widths, duplicate identities, and unsupported stripes are refused"

for mutation in serial size transport sector ineligible; do
  case "${mutation}" in
    serial) jq '.disks[0].serial="DIFFERENT"' "${TMP}/four-sas.json" > "${TMP}/mutated.json" ;;
    size) jq '.disks[0].size_bytes=5500000000000' "${TMP}/four-sas.json" > "${TMP}/mutated.json" ;;
    transport) jq '.disks[0].transport="sata"' "${TMP}/four-sas.json" > "${TMP}/mutated.json" ;;
    sector) jq '.disks[0].physical_sector_bytes=512' "${TMP}/four-sas.json" > "${TMP}/mutated.json" ;;
    ineligible) jq '.disks[0].eligible=false|.disks[0].reasons=["active-ceph"]' "${TMP}/four-sas.json" > "${TMP}/mutated.json" ;;
  esac
  PROXMOX_ZFS_INVENTORY_FIXTURE="${TMP}/mutated.json" expect_failure "${RUNNER}" preflight --config "${CONFIG}"
done
ok "identity, size, transport, sector, and active-use drift are refused"

PROXMOX_ZFS_EXISTING_POOLS=archive expect_failure "${RUNNER}" preflight --config "${CONFIG}"
PROXMOX_ZFS_IMPORTABLE_POOLS=archive expect_failure "${RUNNER}" preflight --config "${CONFIG}"
ok "existing and importable pool names are refused"

jq '.disks[0].signatures=["zfs_member"]|.disks[0].warnings=["signatures-present"]' "${TMP}/four-sas.json" > "${TMP}/signed.json"
mkdir -p "${TMP}/signed-config"
expect_failure bash -c 'cd "$1" && "$2" --inventory-file "$3" --type sas --all-matches --non-interactive --vdev-type raidz2 --vdev-count 1' _ "${TMP}/signed-config" "${CONFIG_RUNNER}" "${TMP}/signed.json"
(
  cd "${TMP}/signed-config"
  "${CONFIG_RUNNER}" --inventory-file "${TMP}/signed.json" --type sas --all-matches --non-interactive \
    --vdev-type raidz2 --vdev-count 1 --allow-signature-wipe >/dev/null
)
SIGNED_CONFIG="${TMP}/signed-config/zpool.config"
PROXMOX_ZFS_INVENTORY_FIXTURE="${TMP}/signed.json" "${RUNNER}" plan --config "${SIGNED_CONFIG}" --plan-file "${TMP}/wipe.plan" >/dev/null
jq -e '.plan_kind=="signature-wipe" and .requires_signature_wipe==true and (.commands.signature_wipes|length)==1' "${TMP}/wipe.plan" >/dev/null || fail "signature wipe plan contract"
expect_failure "${RUNNER}" apply --plan-file "${TMP}/wipe.plan" --plan-id "$(jq -r .plan_id "${TMP}/wipe.plan")" --mode create --confirm-create archive --yes
ok "signature detection, opt-in planning, and create separation"

expect_failure bash -c 'cd "$1" && "$2" --inventory-file "$3" --type sas --all-matches --non-interactive --vdev-type raidz2' _ "${TMP}" "${CONFIG_RUNNER}" "${TMP}/inventory.json"
expect_failure bash -c 'cd "$1" && "$2" --inventory-file "$3" --type sas --non-interactive --vdev-type raidz2 --vdev-count 1' _ "${TMP}" "${CONFIG_RUNNER}" "${TMP}/inventory.json"
ok "non-interactive mode requires deterministic selection and topology"

expect_failure bash -c 'source "$1"; PROXMOX_ZFS_TEST_MODE=0; PROXMOX_ZFS_ENTRYPOINT_FILE=""; zfs.require.regular.entrypoint' _ "${HELPER}"
ok "review and mutation actions require a downloaded regular entrypoint"

grep -RInE 'dragonfruit|10[.]0[.]0[.]|exactly 18|18-disk|two-by-nine|2:9:9|nine-disk' "${RUNNER}" "${CONFIG_RUNNER}" "${HELPER}" && fail "feature contains host or fixed-disk coupling"
grep -Fq -- '--mode create' <("${RUNNER}" --help) || fail "help omits explicit creation mode"
grep -Fq 'y/n/all/none' <("${CONFIG_RUNNER}" --help) || fail "help omits prompt behavior"
ok "public help and implementation remain generic and local"

printf '[validate.storage.zfs] all contracts passed\n'
