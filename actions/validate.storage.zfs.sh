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
      value="$(jq -r --arg property "${property}" '.pool.filesystem_properties[$property] // empty' "${ZFS_TEST_CONFIG}")"
      if [[ "${property}" == "acltype" && -n "${ZFS_TEST_ACLTYPE_OVERRIDE:-}" ]]; then
        printf '%s\n' "${ZFS_TEST_ACLTYPE_OVERRIDE}"
      elif [[ "${property}:${value}" == "acltype:posixacl" ]]; then
        printf 'posix\n'
      else
        printf '%s\n' "${value}"
      fi
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
  hba:"host0",enclosure:"enc0",slot:("0:0:"+($i|tostring)+":0"),observed_hctl:("0:0:"+($i|tostring)+":0"),
  observed_slot_index:$i,observed_slot_source:"scsi-hctl-target",observed_slot_scope:"host0:channel0",
  fault_domain:("host0:enc0:0:0:"+($i|tostring)+":0"),whole_disk:true,
  signatures:[],reasons:[],warnings:[],eligible:true
}]}' > "${TMP}/inventory.json"

jq -n \
  --argjson serials '["Z4D1H51W","Z4D1H3BJ","Z4D1EPDL","Z4D1H4YH","Z4D1H4LZ","Z4D1DEN1","Z4D1H3EL","Z4D1H3HF","Z4D1GFB8","Z4D1H5EH","Z4D1H4JB","Z4D1H4NZ","Z4D1CC4C","Z4D1GF2K","Z4D1GEV2","Z4D1C0N0","Z4D1GF92","Z4D1H50D"]' \
  --argjson wwns '["0x5000c500833c107f","0x5000c500833cb1d3","0x5000c500638f5f43","0x5000c500833c1d67","0x5000c500833c3a83","0x5000c500833ca20b","0x5000c500833c8cf3","0x5000c500833ce3db","0x5000c500833bbfe3","0x5000c500833be943","0x5000c500833c402b","0x5000c500833c352f","0x5000c500833cb9db","0x5000c500833bf0f3","0x5000c500833c0a37","0x5000c500833c98a3","0x5000c500833bc1e7","0x5000c500833c165b"]' '
{schema_version:1,disks:([range(0;18) as $slot | {
    kernel:("sd"+($slot|tostring)),path:("/dev/sd"+($slot|tostring)),
    stable_path:("/dev/disk/by-id/wwn-"+$wwns[$slot]),
    wwn:$wwns[$slot],serial:$serials[$slot],
    model:"ST6000NM0034",vendor:"SEAGATE",transport:"sas",media:"hdd",
    size_bytes:6001175126016,rotational:true,
    logical_sector_bytes:512,physical_sector_bytes:4096,smart_health:"passed",effective_health:"passed",
    health_evidence:{status:"not-supplied"},hba:"host0",enclosure:("target0:0:"+($slot|tostring)),slot:("0:0:"+($slot|tostring)+":0"),
    observed_hctl:("0:0:"+($slot|tostring)+":0"),observed_slot_index:$slot,
    observed_slot_source:"scsi-hctl-target",observed_slot_scope:"host0:channel0",
    fault_domain:("host0:target0:0:"+($slot|tostring)+":0:0:"+($slot|tostring)+":0"),whole_disk:true,
    signatures:[],reasons:[],warnings:[],eligible:true
  }] + [range(0;2) as $i | {
    kernel:("ssd"+($i|tostring)),path:("/dev/ssd"+($i|tostring)),
    stable_path:("/dev/disk/by-id/wwn-0x500a"+(300000000000+$i|tostring)),
    wwn:("0x500a"+(300000000000+$i|tostring)),serial:("SYSTEM"+($i|tostring)),
    model:"MTFDDAV240TDU",vendor:"ATA",transport:"sata",media:"ssd",
    size_bytes:240057409536,rotational:false,
    logical_sector_bytes:512,physical_sector_bytes:4096,smart_health:"passed",effective_health:"passed",
    health_evidence:{status:"not-supplied"},hba:("host"+(11+$i|tostring)),enclosure:"system",slot:((11+$i|tostring)+":0:0:0"),
    observed_hctl:((11+$i|tostring)+":0:0:0"),observed_slot_index:0,
    observed_slot_source:"scsi-hctl-target",observed_slot_scope:("host"+(11+$i|tostring)+":channel0"),
    fault_domain:("system:"+($i|tostring)),whole_disk:true,
    signatures:["PMBR","gpt","zfs_member"],
    reasons:["contains-partitions-or-children"],warnings:["signatures-present"],eligible:false
  }])}' > "${TMP}/large-mixed-inventory.json"

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

smart_passed="$(bash -c 'source "$1"; zfs.health.smart.normalize '\''{"smart_status":{"passed":true}}'\''' _ "${HELPER}")"
smart_failed="$(bash -c 'source "$1"; zfs.health.smart.normalize '\''{"smart_status":{"passed":false}}'\''' _ "${HELPER}")"
smart_unknown="$(bash -c 'source "$1"; zfs.health.smart.normalize "$2"' _ "${HELPER}" $'{"smart_status":{"passed":true}}\nunknown')"
[[ "${smart_passed}" == passed && "${smart_failed}" == failed && "${smart_unknown}" == unknown ]] || fail "SMART normalization"
[[ "$(printf '%s\n' "${smart_unknown}" | wc -l | tr -d ' ')" == 1 ]] || fail "SMART normalization emitted multiple values"
ok "SMART health is normalized to exactly one value"

INTERACTIVE_CANDIDATES="$(jq -c '.disks[0:4]' "${TMP}/inventory.json")"
selection_review="$(bash -c '
  source "$1"
  inventory="$(cat "$2")"
  candidates="$(jq -c ".disks[0:18]" "$2")"
  zfs.config.review.json "${inventory}" "${candidates}" sas hdd "$3" "$4" "[]"
' _ "${HELPER}" "${TMP}/large-mixed-inventory.json" \
  '{"minimum_bytes":5940000000000,"maximum_bytes":6060000000000}' '["ST6000NM0034"]')"
jq -e '
  .review_kind=="zfs-device-selection" and
  .filters.transport=="sas" and .filters.media=="hdd" and
  .summary=={candidate_count:18,discovered_count:20,excluded_count:2,filtered_count:0,ineligible_count:2} and
  (.candidates|length)==18 and all(.candidates[];.selection_status=="candidate" and .eligible==true) and
  (.excluded|length)==2 and all(.excluded[];.selection_status=="ineligible" and (.signatures|index("zfs_member")!=null))
' <<< "${selection_review}" >/dev/null || fail "pretty JSON selection review"
[[ "$(wc -l <<< "${selection_review}" | tr -d ' ')" -gt 20 ]] || fail "selection review is not pretty printed"
candidate_review="$(bash -c '
  source "$1"
  zfs.config.candidate.review.json "$(jq -c ".disks[0]" "$2")" 1 18
' _ "${HELPER}" "${TMP}/large-mixed-inventory.json")"
jq -e '.review_kind=="zfs-device-candidate" and .candidate_index==1 and .candidate_count==18 and .device.serial=="Z4D1H51W" and .device.observed_slot_index==0' \
  <<< "${candidate_review}" >/dev/null || fail "pretty JSON candidate review"
ok "selection and per-candidate reviews are valid pretty JSON"

interactive_selection="$(CANDIDATES="${INTERACTIVE_CANDIDATES}" HELPER="${HELPER}" bash -c '
  source "${HELPER}"
  zfs.prompt() {
    case "$1" in
      *"candidate 1/4"*) printf "y\n" ;;
      *"candidate 2/4"*) printf "n\n" ;;
      *) printf "all\n" ;;
    esac
  }
  zfs.config.choose.interactive "${CANDIDATES}" 2>/dev/null
')"
[[ "$(jq 'length' <<< "${interactive_selection}")" -eq 3 ]] || fail "y/n/all prompt semantics"
yes_yes_all_selection="$(CANDIDATES="${INTERACTIVE_CANDIDATES}" HELPER="${HELPER}" bash -c '
  source "${HELPER}"
  zfs.prompt() {
    case "$1" in
      *"candidate 1/4"*|*"candidate 2/4"*) printf "y\n" ;;
      *) printf "all\n" ;;
    esac
  }
  zfs.config.choose.interactive "${CANDIDATES}" 2>/dev/null
')"
[[ "$(jq -r '[.[].serial]|join(",")' <<< "${yes_yes_all_selection}")" == "SER1,SER2,SER3,SER4" ]] || fail "y/y/all prompt semantics"
none_selection="$(CANDIDATES="${INTERACTIVE_CANDIDATES}" HELPER="${HELPER}" bash -c '
  source "${HELPER}"
  zfs.prompt() { printf "none\n"; }
  zfs.config.choose.interactive "${CANDIDATES}" 2>/dev/null
')"
[[ "$(jq 'length' <<< "${none_selection}")" -eq 0 ]] || fail "none prompt semantics"
ok "interactive y/n/all/none selection"

selected_order_review="$(SELECTED="${INTERACTIVE_CANDIDATES}" HELPER="${HELPER}" bash -c '
  source "${HELPER}"
  zfs.config.selected.order.review.json "${SELECTED}"
')"
jq -e '.review_kind=="zfs-selected-device-order" and .selected_count==4 and .devices[0].order==1 and .devices[0].serial=="SER1" and .devices[0].observed_slot_index==1' \
  <<< "${selected_order_review}" >/dev/null || fail "selected order JSON rendering"
reordered="$(SELECTED="${INTERACTIVE_CANDIDATES}" HELPER="${HELPER}" bash -c '
  source "${HELPER}"
  zfs.config.reorder.by.indexes "${SELECTED}" "4, 2, 1, 3"
')"
[[ "$(jq -r '[.[].serial]|join(",")' <<< "${reordered}")" == "SER4,SER2,SER1,SER3" ]] || fail "selected order reordering"
unchanged_order="$(SELECTED="${INTERACTIVE_CANDIDATES}" HELPER="${HELPER}" bash -c '
  source "${HELPER}"
  zfs.prompt() { printf "\n"; }
  zfs.config.reorder.interactive "${SELECTED}" 2>/dev/null
')"
[[ "$(jq -r '[.devices[].serial]|join(",")' <<< "${unchanged_order}")" == "SER1,SER2,SER3,SER4" ]] || fail "interactive selected order rendering"
expect_failure bash -c 'source "$1"; zfs.config.reorder.by.indexes "$2" "1,1,3,4"' _ "${HELPER}" "${INTERACTIVE_CANDIDATES}"
expect_failure bash -c 'source "$1"; zfs.config.reorder.by.indexes "$2" "1,2,3"' _ "${HELPER}" "${INTERACTIVE_CANDIDATES}"
expect_failure bash -c 'source "$1"; zfs.config.reorder.by.indexes "$2" "1,2,3,5"' _ "${HELPER}" "${INTERACTIVE_CANDIDATES}"
ok "selected order JSON and CSV reordering reject duplicates, omissions, and out-of-range indexes"

SLOT_CANDIDATES="$(jq -c '.disks[0:18] | sort_by(.stable_path)' "${TMP}/large-mixed-inventory.json")"
slot_order="$(SELECTED="${SLOT_CANDIDATES}" HELPER="${HELPER}" bash -c '
  source "${HELPER}"
  zfs.config.order.resolve "${SELECTED}" slot 0
')"
jq -e '
  .requested=="slot" and .effective=="slot" and .source=="scsi-hctl-target" and .requires_manual==false and
  [.devices[].observed_slot_index]==[range(0;18)] and
  [.devices[].serial]==["Z4D1H51W","Z4D1H3BJ","Z4D1EPDL","Z4D1H4YH","Z4D1H4LZ","Z4D1DEN1","Z4D1H3EL","Z4D1H3HF","Z4D1GFB8","Z4D1H5EH","Z4D1H4JB","Z4D1H4NZ","Z4D1CC4C","Z4D1GF2K","Z4D1GEV2","Z4D1C0N0","Z4D1GF92","Z4D1H50D"]
' <<< "${slot_order}" >/dev/null || fail "numeric slot ordering"
explicit_order="$(SELECTED="$(jq -c 'reverse' <<< "${INTERACTIVE_CANDIDATES}")" HELPER="${HELPER}" bash -c '
  source "${HELPER}"
  zfs.config.order.resolve "${SELECTED}" auto 1
')"
[[ "$(jq -r '[.devices[].serial]|join(",")' <<< "${explicit_order}")" == "SER4,SER3,SER2,SER1" ]] || fail "explicit identifier order was not preserved"
ambiguous_slots="$(jq -c '.[1].observed_slot_index=.[0].observed_slot_index' <<< "${INTERACTIVE_CANDIDATES}")"
ambiguous_order="$(SELECTED="${ambiguous_slots}" HELPER="${HELPER}" bash -c '
  source "${HELPER}"
  zfs.config.order.resolve "${SELECTED}" auto 0
' 2>/dev/null)"
jq -e '.effective=="manual-required" and .requires_manual==true' <<< "${ambiguous_order}" >/dev/null || fail "ambiguous auto order did not require manual review"
expect_failure bash -c 'source "$1"; zfs.config.order.resolve "$2" slot 0' _ "${HELPER}" "${ambiguous_slots}"
multi_scope="$(jq -c '.[1].observed_slot_scope="host1:channel0"' <<< "${INTERACTIVE_CANDIDATES}")"
expect_failure bash -c 'source "$1"; zfs.config.order.resolve "$2" slot 0' _ "${HELPER}" "${multi_scope}"
mkdir -p "${TMP}/sys-enclosure/enclosure0/Slot 07/device/block/sdz"
printf '7\n' > "${TMP}/sys-enclosure/enclosure0/Slot 07/slot"
enclosure_slot="$(PROXMOX_ZFS_SYS_ENCLOSURE_ROOT="${TMP}/sys-enclosure" bash -c '
  source "$1"
  zfs.device.enclosure.slot sdz
' _ "${HELPER}")"
[[ "${enclosure_slot}" == $'enclosure:enclosure0\t7' ]] || fail "native sysfs enclosure slot discovery"
ok "slot order is numeric, explicit selection is authoritative, and ambiguous layouts do not fall back silently"

jq '.disks=.disks[0:4]' "${TMP}/inventory.json" > "${TMP}/four-sas.json"

jq '
  .disks[0].smart_health="unknown" |
  .disks[1].smart_health="failed" |
  .disks[2].reasons=["active-ceph"] |
  .disks[2].eligible=false
' "${TMP}/four-sas.json" > "${TMP}/health-policy.json"
PROXMOX_ZFS_INVENTORY_FIXTURE="${TMP}/health-policy.json" \
  bash -c 'source "$1"; zfs.inventory.collect advisory' _ "${HELPER}" > "${TMP}/health-advisory.json"
jq -e '
  .health_policy=="advisory" and
  .disks[0].eligible==true and .disks[0].effective_health=="advisory" and (.disks[0].warnings|index("smart-unknown-advisory")!=null) and
  .disks[1].eligible==true and .disks[1].effective_health=="advisory" and (.disks[1].warnings|index("smart-failed-advisory")!=null) and
  .disks[2].eligible==false and (.disks[2].reasons|index("active-ceph")!=null)
' "${TMP}/health-advisory.json" >/dev/null || fail "advisory health policy"
PROXMOX_ZFS_INVENTORY_FIXTURE="${TMP}/health-policy.json" \
  bash -c 'source "$1"; zfs.inventory.collect smart-required' _ "${HELPER}" > "${TMP}/health-smart-required.json"
jq -e '
  .health_policy=="smart-required" and
  .disks[0].eligible==false and (.disks[0].reasons|index("smart-required-unknown")!=null) and
  .disks[1].eligible==false and (.disks[1].reasons|index("smart-required-failed")!=null) and
  .disks[3].eligible==true
' "${TMP}/health-smart-required.json" >/dev/null || fail "smart-required health policy"
ok "SMART is advisory by default, opt-in when required, and never clears hard hazards"

jq '{
  schema_version:1,
  kind:"bht_offline_drive_reference",
  generated_at:"2026-09-25T00:00:00Z",
  drives:[.disks[] | {
    serial,model,server:"fixture",run_id:"run-1",
    bht_completed_at:"2026-09-24T00:00:00Z",bht_status:"complete",bht_progress_percent:100,
    bht_errors:[],bht_patterns:["0xaa","0x55","0xff","0x00"],smart_passed:true,
    grade:"A",confidence:"partial",disposition:"passed_monitor",
    production_readiness:"ready_sustained_writes_and_casual_reads",
    evidence_source_digest:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",evidence_package:("fixture/"+.serial)
  }]
}' "${TMP}/four-sas.json" > "${TMP}/bht-reference.json"
export PROXMOX_ZFS_HEALTH_NOW_EPOCH
PROXMOX_ZFS_HEALTH_NOW_EPOCH="$(jq -nr '"2026-09-25T00:00:00Z"|fromdateiso8601')"
PROXMOX_ZFS_INVENTORY_FIXTURE="${TMP}/four-sas.json" \
  bash -c 'source "$1"; zfs.inventory.collect bht-required "$2" "" fixture 30' \
  _ "${HELPER}" "${TMP}/bht-reference.json" > "${TMP}/health-bht-required.json"
jq -e '
  .health_policy=="bht-required" and
  all(.disks[];.eligible==true and .effective_health=="passed" and .health_evidence.status=="accepted" and .health_evidence.package_verification=="not-requested")
' "${TMP}/health-bht-required.json" >/dev/null || fail "accepted BHT policy"
jq '.drives[0].grade="B"' "${TMP}/bht-reference.json" > "${TMP}/bht-rejected.json"
PROXMOX_ZFS_INVENTORY_FIXTURE="${TMP}/four-sas.json" \
  bash -c 'source "$1"; zfs.inventory.collect bht-required "$2" "" fixture 30' \
  _ "${HELPER}" "${TMP}/bht-rejected.json" > "${TMP}/health-bht-rejected.json"
jq -e '.disks[0].eligible==false and .disks[0].health_evidence.status=="rejected" and (.disks[0].reasons|index("bht-required-rejected")!=null)' \
  "${TMP}/health-bht-rejected.json" >/dev/null || fail "rejected BHT policy"
PROXMOX_ZFS_INVENTORY_FIXTURE="${TMP}/four-sas.json" \
  bash -c 'source "$1"; zfs.inventory.collect advisory "$2" "" fixture 30' \
  _ "${HELPER}" "${TMP}/bht-rejected.json" > "${TMP}/health-bht-advisory.json"
jq -e '.disks[0].eligible==true and .disks[0].health_evidence.status=="rejected" and (.disks[0].warnings|index("bht-evidence-rejected")!=null)' \
  "${TMP}/health-bht-advisory.json" >/dev/null || fail "advisory BHT policy"
ok "optional BHT evidence can be advisory or explicitly required"

CONFIG="${TMP}/work/zpool.config"
(
  cd "${TMP}/work"
  "${RUNNER}" --inventory-file "${TMP}/four-sas.json" --type sas --media hdd --size 6TB \
    --all-matches --non-interactive --vdev-type raidz2 --vdev-count 1 \
    --mountpoint "${TMP}/mount" >/dev/null
)
[[ "$(stat -c '%a' "${CONFIG}" 2>/dev/null || stat -f '%Lp' "${CONFIG}")" == 600 ]] || fail "zpool.config mode is not 0600"
jq -e '
  .pool.name=="zfspool" and .datasets[0].name=="zfspool/archive" and
  .selection.filters.size_bytes=={minimum_bytes:5940000000000,maximum_bytes:6060000000000} and
  .selection.health.policy=="advisory" and .selection.health.evidence.supplied==false and
  .selection.ordering=={effective:"slot",requested:"auto",source:"scsi-hctl-target"} and
  .topology.grouping=="contiguous" and
  (.vdevs|length)==1 and .vdevs[0].type=="raidz2" and (.vdevs[0].devices|length)==4 and
  all(.vdevs[].devices[];.expected_transport=="sas" and .expected_size_bytes==6000000000000 and .logical_sector_bytes==512 and .physical_sector_bytes==4096 and (.observed_slot_index|type)=="number")
' "${CONFIG}" >/dev/null || fail "general configuration contract"
"${RUNNER}" validate-config --config "${CONFIG}" >/dev/null
ok "flag-first configure writes editable dynamic topology"

mkdir -p "${TMP}/default-config"
default_review="$(
  cd "${TMP}/default-config"
  "${CONFIG_RUNNER}" --inventory-file "${TMP}/four-sas.json" --type sas --all-matches \
    --non-interactive --vdev-type raidz2 --vdev-count 1
)"
jq -e '.review_kind=="zfs-device-selection" and .summary.candidate_count==4 and (.candidates|length)==4' \
  <<< "${default_review}" >/dev/null || fail "configure did not emit a valid default JSON review"
DEFAULT_CONFIG="${TMP}/default-config/zpool.config"
jq -e '
  .pool.name=="zfspool" and
  .pool.filesystem_properties.mountpoint=="none" and .pool.filesystem_properties.canmount=="off" and
  .datasets==[{mountpoint:"/media/zfspool/archive",name:"zfspool/archive",properties:{canmount:"on",dedup:"off",recordsize:"1M"}}]
' "${DEFAULT_CONFIG}" >/dev/null || fail "default pool, dataset, and mountpoint hierarchy"
"${RUNNER}" validate-config --config "${DEFAULT_CONFIG}" >/dev/null

mkdir -p "${TMP}/nested-dataset-config"
(
  cd "${TMP}/nested-dataset-config"
  "${CONFIG_RUNNER}" --inventory-file "${TMP}/four-sas.json" --type sas --all-matches \
    --non-interactive --vdev-type raidz2 --vdev-count 1 \
    --pool tank --dataset tank/archive/deep >/dev/null
)
jq -e '.pool.name=="tank" and .datasets[0].name=="tank/archive/deep" and .datasets[0].mountpoint=="/media/tank/archive/deep"' \
  "${TMP}/nested-dataset-config/zpool.config" >/dev/null || fail "dataset-derived mountpoint"

mkdir -p "${TMP}/legacy-names-config"
(
  cd "${TMP}/legacy-names-config"
  "${CONFIG_RUNNER}" --inventory-file "${TMP}/four-sas.json" --type sas --all-matches \
    --non-interactive --vdev-type raidz2 --vdev-count 1 \
    --pool archive --dataset archive/samba --mountpoint /media/archive >/dev/null
)
LEGACY_NAMES_CONFIG="${TMP}/legacy-names-config/zpool.config"
jq -e '.pool.name=="archive" and .datasets[0].name=="archive/samba" and .datasets[0].mountpoint=="/media/archive"' \
  "${LEGACY_NAMES_CONFIG}" >/dev/null || fail "explicit legacy naming"
"${RUNNER}" validate-config --config "${LEGACY_NAMES_CONFIG}" >/dev/null
expect_failure bash -c 'cd "$1" && "$2" --inventory-file "$3" --type sas --all-matches --non-interactive --vdev-type raidz2 --vdev-count 1 --review-format yaml' \
  _ "${TMP}" "${CONFIG_RUNNER}" "${TMP}/four-sas.json"
ok "new storage hierarchy and nested mountpoint derivation preserve explicit legacy names"

mkdir -p "${TMP}/large-mixed-config"
(
  cd "${TMP}/large-mixed-config"
  "${CONFIG_RUNNER}" --inventory-file "${TMP}/large-mixed-inventory.json" \
    --type sas --media hdd --size 6TB --model ST6000NM0034 --all-matches \
    --device-order slot --non-interactive --vdev-type raidz2 --vdev-count 2 >/dev/null
)
LARGE_MIXED_CONFIG="${TMP}/large-mixed-config/zpool.config"
jq -e '
  (.vdevs|length)==2 and all(.vdevs[];.type=="raidz2" and (.devices|length)==9) and
  ([.vdevs[].devices[]]|length)==18 and
  .selection.ordering=={effective:"slot",requested:"slot",source:"scsi-hctl-target"} and .topology.grouping=="contiguous" and
  [.vdevs[0].devices[].observed_slot_index]==[0,1,2,3,4,5,6,7,8] and
  [.vdevs[1].devices[].observed_slot_index]==[9,10,11,12,13,14,15,16,17] and
  [.vdevs[0].devices[].expected_serial]==["Z4D1H51W","Z4D1H3BJ","Z4D1EPDL","Z4D1H4YH","Z4D1H4LZ","Z4D1DEN1","Z4D1H3EL","Z4D1H3HF","Z4D1GFB8"] and
  [.vdevs[1].devices[].expected_serial]==["Z4D1H5EH","Z4D1H4JB","Z4D1H4NZ","Z4D1CC4C","Z4D1GF2K","Z4D1GEV2","Z4D1C0N0","Z4D1GF92","Z4D1H50D"] and
  all(.vdevs[].devices[];.expected_transport=="sas" and .expected_size_bytes==6001175126016) and
  ([.vdevs[].devices[].expected_serial]|unique|length)==18
' "${LARGE_MIXED_CONFIG}" >/dev/null || fail "large mixed inventory topology"
"${RUNNER}" validate-config --config "${LARGE_MIXED_CONFIG}" >/dev/null
ok "large mixed inventory produces two equal nine-member RAIDZ2 vdevs without selecting system SSDs"

jq '.disks[1].observed_slot_scope="host1:channel0"' "${TMP}/four-sas.json" > "${TMP}/ambiguous-scope.json"
mkdir -p "${TMP}/ambiguous-order-config" "${TMP}/stable-order-config"
expect_failure bash -c 'cd "$1" && "$2" --inventory-file "$3" --type sas --all-matches --non-interactive --vdev-type raidz2 --vdev-count 1' \
  _ "${TMP}/ambiguous-order-config" "${CONFIG_RUNNER}" "${TMP}/ambiguous-scope.json"
(
  cd "${TMP}/stable-order-config"
  "${CONFIG_RUNNER}" --inventory-file "${TMP}/ambiguous-scope.json" --type sas --all-matches \
    --device-order stable-path --non-interactive --vdev-type raidz2 --vdev-count 1 >/dev/null
)
jq -e '.selection.ordering=={effective:"stable-path",requested:"stable-path",source:"stable-path"}' \
  "${TMP}/stable-order-config/zpool.config" >/dev/null || fail "explicit stable-path compatibility order"
ok "ambiguous controller scopes require an explicit order and stable-path remains opt-in"

mkdir -p "${TMP}/bht-config"
(
  cd "${TMP}/bht-config"
  "${CONFIG_RUNNER}" --inventory-file "${TMP}/four-sas.json" --type sas --all-matches \
    --non-interactive --vdev-type raidz2 --vdev-count 1 \
    --health-policy bht-required --health-evidence "${TMP}/bht-reference.json" --evidence-server fixture >/dev/null
)
BHT_CONFIG="${TMP}/bht-config/zpool.config"
jq -e '
  .selection.health.policy=="bht-required" and .selection.health.evidence.supplied==true and
  all(.vdevs[].devices[];.expected_health.policy=="bht-required" and .expected_health.evidence_source_digest=="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
' "${BHT_CONFIG}" >/dev/null || fail "BHT configuration contract"
PROXMOX_ZFS_INVENTORY_FIXTURE="${TMP}/four-sas.json" \
  "${RUNNER}" preflight --config "${BHT_CONFIG}" --health-evidence "${TMP}/bht-reference.json" >/dev/null
PROXMOX_ZFS_INVENTORY_FIXTURE="${TMP}/four-sas.json" \
  expect_failure "${RUNNER}" preflight --config "${BHT_CONFIG}"
ok "required BHT evidence is pinned into configuration and revalidated"

mkdir -p "${TMP}/serial-config"
(
  cd "${TMP}/serial-config"
  "${CONFIG_RUNNER}" --inventory-file "${TMP}/four-sas.json" --type sas --model ' test ' \
    --serial='[SER4, SER2, SER1, SER3]' \
    --non-interactive --vdev-type raidz2 --vdev-count 1 >/dev/null
)
jq -e '
  [.vdevs[].devices[].expected_serial]==["SER4","SER2","SER1","SER3"] and
  .selection.ordering=={effective:"selection",requested:"auto",source:"explicit-identifiers"} and
  .selection.filters.models==[" test "] and
  .selection.filters.serials==["SER4","SER2","SER1","SER3"]
' "${TMP}/serial-config/zpool.config" >/dev/null || fail "serial/model selection"
printf '# reviewed serials\nSER3\n\nSER1\n' > "${TMP}/serials.txt"
mkdir -p "${TMP}/serial-file-config"
(
  cd "${TMP}/serial-file-config"
  "${CONFIG_RUNNER}" --inventory-file "${TMP}/four-sas.json" --serial "${TMP}/serials.txt" \
    --non-interactive --vdev-type mirror --vdev-count 1 >/dev/null
)
jq -e '[.vdevs[].devices[].expected_serial]==["SER3","SER1"]' \
  "${TMP}/serial-file-config/zpool.config" >/dev/null || fail "serial file selection"
: > "${TMP}/empty-serials.txt"
expect_failure bash -c 'source "$1"; zfs.serial.selection.read "$2"' _ "${HELPER}" "${TMP}/empty-serials.txt"
expect_failure bash -c 'cd "$1" && "$2" --inventory-file "$3" --serial="[SER1,SER1]" --non-interactive --vdev-type mirror --vdev-count 1' \
  _ "${TMP}" "${CONFIG_RUNNER}" "${TMP}/four-sas.json"
expect_failure bash -c 'cd "$1" && "$2" --inventory-file "$3" --serial="[SER1,SER2]" --device SER2 --non-interactive --vdev-type mirror --vdev-count 1' \
  _ "${TMP}" "${CONFIG_RUNNER}" "${TMP}/four-sas.json"
ok "exact model filtering and ordered serial array/file selection"

jq '.disks[].hba="host0"|.disks[].fault_domain="host0:shared"' "${TMP}/four-sas.json" > "${TMP}/single-hba.json"
mkdir -p "${TMP}/single-hba-config"
(
  cd "${TMP}/single-hba-config"
  "${CONFIG_RUNNER}" --inventory-file "${TMP}/single-hba.json" --type sas --all-matches \
    --non-interactive --vdev-type raidz2 --vdev-count 1 >/dev/null
)
jq -e '.topology.observed_hbas==["host0"] and (.topology.advisories|index("single-hba")!=null)' \
  "${TMP}/single-hba-config/zpool.config" >/dev/null || fail "single-HBA advisory"
ok "single-HBA topology is recorded as a non-blocking advisory"

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
  .configuration.pool.filesystem_properties.acltype=="posix" and
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
jq '.disks[0].smart_health="failed"|.disks[1].smart_health="unknown"' "${TMP}/four-sas.json" > "${TMP}/advisory-health-drift.json"
PROXMOX_ZFS_INVENTORY_FIXTURE="${TMP}/advisory-health-drift.json" \
  bash -c 'source "$1"; zfs.plan.revalidate "$2"' _ "${HELPER}" "${PLAN}"
cp "${CONFIG}" "${TMP}/config.saved"
printf '\n' >> "${CONFIG}"
expect_failure bash -c 'source "$1"; zfs.plan.revalidate "$2"' _ "${HELPER}" "${PLAN}"
mv "${TMP}/config.saved" "${CONFIG}"
"${RUNNER}" verify --config "${CONFIG}" >/dev/null
LEGACY_ACL_CONFIG="${TMP}/legacy-posixacl.config"
jq '.pool.filesystem_properties.acltype="posixacl"' "${CONFIG}" > "${LEGACY_ACL_CONFIG}"
ZFS_TEST_CONFIG="${LEGACY_ACL_CONFIG}" ZFS_TEST_ACLTYPE_OVERRIDE=posix \
  "${RUNNER}" verify --config "${LEGACY_ACL_CONFIG}" >/dev/null
ZFS_TEST_CONFIG="${LEGACY_ACL_CONFIG}" ZFS_TEST_ACLTYPE_OVERRIDE=nfsv4 \
  expect_failure "${RUNNER}" verify --config "${LEGACY_ACL_CONFIG}"
ok "dynamic planning, property alias normalization, config invalidation, capacity estimate, dry-run, and verification"

PLAN_ID="$(jq -r '.plan_id' "${PLAN}")"
"${RUNNER}" apply \
  --plan-file "${PLAN}" \
  --plan-id "${PLAN_ID}" \
  --mode create \
  --confirm-create zfspool \
  --yes >/dev/null
ACCEPTED_STATE_DIR="${TMP}/state/zfspool"
[[ -f "${ACCEPTED_STATE_DIR}/accepted-plan.json" ]] || fail "apply did not preserve accepted plan"
[[ -f "${ACCEPTED_STATE_DIR}/accepted-config.json" ]] || fail "apply did not preserve accepted configuration"
cmp "${CONFIG}" "${ACCEPTED_STATE_DIR}/accepted-config.json" >/dev/null || fail "accepted configuration differs from reviewed configuration"
[[ "$(stat -c '%a' "${ACCEPTED_STATE_DIR}/accepted-plan.json" 2>/dev/null || stat -f '%Lp' "${ACCEPTED_STATE_DIR}/accepted-plan.json")" == 600 ]] || fail "accepted plan mode is not 0600"
[[ "$(stat -c '%a' "${ACCEPTED_STATE_DIR}/accepted-config.json" 2>/dev/null || stat -f '%Lp' "${ACCEPTED_STATE_DIR}/accepted-config.json")" == 600 ]] || fail "accepted configuration mode is not 0600"
jq -e --arg plan_id "${PLAN_ID}" '.stage=="verified" and .plan_id==$plan_id' \
  "${ACCEPTED_STATE_DIR}/state.json" >/dev/null || fail "apply did not reach verified state"
grep -Fq 'create -o ashift=12' "${TMP}/commands.log" || fail "apply did not execute reviewed pool creation"
grep -Fq 'create -o mountpoint=' "${TMP}/commands.log" || fail "apply did not execute reviewed dataset creation"
ok "apply persists regular accepted inputs and reaches post-create verification"

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

for mutation in serial size transport sector slot ineligible; do
  case "${mutation}" in
    serial) jq '.disks[0].serial="DIFFERENT"' "${TMP}/four-sas.json" > "${TMP}/mutated.json" ;;
    size) jq '.disks[0].size_bytes=5500000000000' "${TMP}/four-sas.json" > "${TMP}/mutated.json" ;;
    transport) jq '.disks[0].transport="sata"' "${TMP}/four-sas.json" > "${TMP}/mutated.json" ;;
    sector) jq '.disks[0].physical_sector_bytes=512' "${TMP}/four-sas.json" > "${TMP}/mutated.json" ;;
    slot) jq '.disks[0].observed_slot_index=99|.disks[0].observed_hctl="0:0:99:0"' "${TMP}/four-sas.json" > "${TMP}/mutated.json" ;;
    ineligible) jq '.disks[0].eligible=false|.disks[0].reasons=["active-ceph"]' "${TMP}/four-sas.json" > "${TMP}/mutated.json" ;;
  esac
  PROXMOX_ZFS_INVENTORY_FIXTURE="${TMP}/mutated.json" expect_failure "${RUNNER}" preflight --config "${CONFIG}"
done
ok "identity, size, transport, sector, slot, and active-use drift are refused"

PROXMOX_ZFS_EXISTING_POOLS=zfspool expect_failure "${RUNNER}" preflight --config "${CONFIG}"
PROXMOX_ZFS_IMPORTABLE_POOLS=zfspool expect_failure "${RUNNER}" preflight --config "${CONFIG}"
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
expect_failure "${RUNNER}" apply --plan-file "${TMP}/wipe.plan" --plan-id "$(jq -r .plan_id "${TMP}/wipe.plan")" --mode create --confirm-create zfspool --yes
ok "signature detection, opt-in planning, and create separation"

expect_failure bash -c 'cd "$1" && "$2" --inventory-file "$3" --type sas --all-matches --non-interactive --vdev-type raidz2' _ "${TMP}" "${CONFIG_RUNNER}" "${TMP}/inventory.json"
expect_failure bash -c 'cd "$1" && "$2" --inventory-file "$3" --type sas --non-interactive --vdev-type raidz2 --vdev-count 1' _ "${TMP}" "${CONFIG_RUNNER}" "${TMP}/inventory.json"
ok "non-interactive mode requires deterministic selection and topology"

expect_failure bash -c 'source "$1"; PROXMOX_ZFS_TEST_MODE=0; PROXMOX_ZFS_ENTRYPOINT_FILE=""; zfs.require.regular.entrypoint' _ "${HELPER}"
ok "review and mutation actions require a downloaded regular entrypoint"

grep -RInE 'dragonfruit|10[.]0[.]0[.]|exactly 18|18-disk|two-by-nine|2:9:9|nine-disk' "${RUNNER}" "${CONFIG_RUNNER}" "${HELPER}" && fail "feature contains host or fixed-disk coupling"
grep -Fq -- '--mode create' <("${RUNNER}" --help) || fail "help omits explicit creation mode"
grep -Fq 'y/n/all/none' <("${CONFIG_RUNNER}" --help) || fail "help omits prompt behavior"
grep -Fq -- '--review-format FORMAT' <("${CONFIG_RUNNER}" --help) || fail "help omits review format"
grep -Fq -- '--device-order MODE' <("${CONFIG_RUNNER}" --help) || fail "help omits device ordering policy"
grep -Fq -- 'default: zfspool' <("${CONFIG_RUNNER}" --help) || fail "help omits storage-specific pool default"
ok "public help and implementation remain generic and local"

printf '[validate.storage.zfs] all contracts passed\n'
