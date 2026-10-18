#!/usr/bin/env bash
# Shared implementation for setup/storage/zfs.sh and zpool.config.sh.
# This file is sourced by the public entrypoints.

ZFS_FEATURE_VERSION="0.0.6"
ZFS_DEFAULT_SIZE_TOLERANCE_PERCENT="1"
ZFS_DEFAULT_HEALTH_POLICY="advisory"
ZFS_DEFAULT_HEALTH_EVIDENCE_AGE_DAYS="30"
ZFS_DEFAULT_POOL="zfspool"
ZFS_DEFAULT_DATASET_LEAF="archive"
ZFS_DEFAULT_REVIEW_FORMAT="pretty-json"
ZFS_DEFAULT_DEVICE_ORDER="auto"
ZFS_DEFAULT_STATE_ROOT="${PROXMOX_ZFS_STATE_ROOT:-/var/lib/proxmox-zfs-feature}"

zfs.log() { printf '[setup.storage.zfs] %s\n' "$*" >&2; }
zfs.warn() { printf '[setup.storage.zfs][warn] %s\n' "$*" >&2; }
zfs.die() { printf '[setup.storage.zfs][error] %s\n' "$*" >&2; exit "${2:-1}"; }

zfs.require.command() {
  command -v "$1" >/dev/null 2>&1 || zfs.die "Missing required command: $1"
}

zfs.require.base.commands() {
  local command_name
  for command_name in bash jq awk sed sort; do
    zfs.require.command "${command_name}"
  done
}

zfs.install.dependencies() {
  zfs.require.root
  command -v apt-get >/dev/null 2>&1 || zfs.die "--install-deps requires apt-get on a Debian-family host"
  zfs.log "Installing explicit ZFS feature dependencies"
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    jq util-linux smartmontools lvm2 mdadm zfsutils-linux
}

zfs.sha256() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    zfs.die "sha256sum or shasum is required"
  fi
}

zfs.is.true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

zfs.health.policy.validate() {
  case "$1" in
    advisory|smart-required|bht-required) ;;
    *) zfs.die "Health policy must be advisory, smart-required, or bht-required" ;;
  esac
}

zfs.health.smart.normalize() {
  local smart_json="$1" health=""
  [[ -n "${smart_json}" ]] || smart_json='{}'
  if health="$(jq -esr '
    if length != 1 or (.[0]|type)!="object" then "unknown"
    elif .[0].smart_status.passed == true then "passed"
    elif .[0].smart_status.passed == false then "failed"
    else "unknown" end
  ' <<< "${smart_json}" 2>/dev/null)"; then
    case "${health}" in
      passed|failed|unknown) printf '%s\n' "${health}" ;;
      *) printf 'unknown\n' ;;
    esac
  else
    printf 'unknown\n'
  fi
}

zfs.health.evidence.validate() {
  local evidence="$1"
  [[ -r "${evidence}" ]] || zfs.die "Health evidence is unreadable: ${evidence}"
  jq -e '
    .schema_version == 1 and
    .kind == "bht_offline_drive_reference" and
    (.generated_at | type == "string") and
    (.drives | type == "array") and
    all(.drives[];
      (.serial | type == "string" and length > 0) and
      (.model | type == "string" and length > 0) and
      (.server | type == "string" and length > 0)
    )
  ' "${evidence}" >/dev/null || zfs.die "Unsupported or invalid BHT health evidence: ${evidence}"
}

zfs.health.evidence.hash() {
  local evidence="$1" canonical
  canonical="$(mktemp)"
  jq -S . "${evidence}" > "${canonical}"
  zfs.sha256 "${canonical}"
  rm -f "${canonical}"
}

zfs.health.package.verify() {
  local root="$1" relative="$2" canonical_root package
  [[ -n "${root}" ]] || return 2
  [[ -d "${root}" && ! -L "${root}" ]] || return 1
  case "${relative}" in
    ""|/*|*..*) return 1 ;;
  esac
  canonical_root="$(cd "${root}" && pwd -P)" || return 1
  package="${canonical_root}/${relative}"
  [[ -d "${package}" && ! -L "${package}" && -f "${package}/SHA256SUMS" ]] || return 1
  case "$(cd "${package}" && pwd -P)" in
    "${canonical_root}"/*) ;;
    *) return 1 ;;
  esac
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${package}" && sha256sum -c SHA256SUMS >/dev/null 2>&1)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "${package}" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1)
  else
    return 1
  fi
}

zfs.health.package.verifications() {
  local evidence="$1" root="$2" server="$3" output="$4" row serial model row_server relative verified
  printf '[]\n' > "${output}"
  [[ -n "${root}" ]] || return 0
  while IFS= read -r row; do
    serial="$(jq -r '.serial' <<< "${row}")"
    model="$(jq -r '.model' <<< "${row}")"
    row_server="$(jq -r '.server' <<< "${row}")"
    relative="$(jq -r '.evidence_package // ""' <<< "${row}")"
    verified=false
    if zfs.health.package.verify "${root}" "${relative}"; then verified=true; fi
    jq -c --arg serial "${serial}" --arg model "${model}" --arg server "${row_server}" \
      --argjson verified "${verified}" '. + [{serial:$serial,model:$model,server:$server,verified:$verified}]' \
      "${output}" > "${output}.next"
    mv "${output}.next" "${output}"
  done < <(jq -c --arg server "${server}" '.drives[] | select($server=="" or .server==$server)' "${evidence}")
}

zfs.inventory.apply.health() {
  local inventory="$1" output="$2" policy="$3" evidence="$4" evidence_root="$5" evidence_server="$6" max_age_days="$7"
  local evidence_file verifications evidence_hash="" now_epoch
  zfs.health.policy.validate "${policy}"
  [[ "${max_age_days}" =~ ^[0-9]+$ && "${max_age_days}" -gt 0 ]] || zfs.die "Health evidence age must be a positive whole number of days"
  if [[ "${policy}" == "bht-required" && -z "${evidence}" ]]; then
    zfs.die "bht-required requires --health-evidence"
  fi
  evidence_file="$(mktemp)"
  verifications="$(mktemp)"
  if [[ -n "${evidence}" ]]; then
    zfs.health.evidence.validate "${evidence}"
    jq -S . "${evidence}" > "${evidence_file}"
    evidence_hash="$(zfs.sha256 "${evidence_file}")"
    zfs.health.package.verifications "${evidence_file}" "${evidence_root}" "${evidence_server}" "${verifications}"
  else
    jq -n '{schema_version:1,kind:"bht_offline_drive_reference",generated_at:"",drives:[]}' > "${evidence_file}"
    printf '[]\n' > "${verifications}"
  fi
  now_epoch="${PROXMOX_ZFS_HEALTH_NOW_EPOCH:-$(date -u +%s)}"
  jq -S \
    --arg policy "${policy}" --arg evidence_hash "${evidence_hash}" --arg evidence_server "${evidence_server}" \
    --argjson max_age_days "${max_age_days}" --argjson now_epoch "${now_epoch}" --argjson package_checks_requested "$( [[ -n "${evidence_root}" ]] && printf true || printf false )" \
    --slurpfile evidence "${evidence_file}" --slurpfile verifications "${verifications}" '
    def norm_model: ascii_downcase | gsub("[[:space:]]+"; " ") | gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def smart_state:
      (.smart_health // "unknown") as $health |
      if ($health == "passed" or $health == "failed" or $health == "unknown") then $health else "unknown" end;
    def normalized_hctl:
      if ((.observed_hctl // "") | type)=="string" and ((.observed_hctl // "") | test("^[0-9]+:[0-9]+:[0-9]+:[0-9]+$")) then .observed_hctl
      elif ((.slot // "") | type)=="string" and ((.slot // "") | test("^[0-9]+:[0-9]+:[0-9]+:[0-9]+$")) then .slot
      else "" end;
    def normalized_slot_index:
      if ((.observed_slot_index // null) | type)=="number" then .observed_slot_index
      elif ((.slot // null) | type)=="number" then .slot
      elif ((.slot // "") | type)=="string" and ((.slot // "") | test("^[0-9]+$")) then (.slot | tonumber)
      elif (normalized_hctl | length)>0 then (normalized_hctl | split(":")[2] | tonumber)
      else null end;
    def normalized_slot_source:
      if ((.observed_slot_source // "") | length)>0 then .observed_slot_source
      elif (normalized_hctl | length)>0 then "scsi-hctl-target"
      elif normalized_slot_index != null then "inventory-slot"
      else "" end;
    def normalized_slot_scope:
      if ((.observed_slot_scope // "") | length)>0 then .observed_slot_scope
      elif (normalized_hctl | length)>0 then
        (normalized_hctl | split(":")) as $parts | "host"+$parts[0]+":channel"+$parts[1]
      elif normalized_slot_index != null then (.hba // "unknown")+":"+(.enclosure // "unknown")
      else "" end;
    def bht_matches($disk):
      [$evidence[0].drives[] |
        select(($evidence_server == "" or .server == $evidence_server) and .serial == $disk.serial and ((.model|norm_model) == ($disk.model|norm_model)))];
    def package_verified($row):
      [$verifications[0][] | select(.serial==$row.serial and .model==$row.model and .server==$row.server) | .verified] |
      if length == 1 then .[0] else false end;
    def evidence_record($disk):
      (bht_matches($disk)) as $matches |
      if ($evidence[0].drives|length) == 0 then
        {status:"not-supplied",accepted:false,file_sha256:null,package_verification:"not-requested"}
      elif ($matches|length) == 0 then
        {status:"missing",accepted:false,file_sha256:$evidence_hash,package_verification:(if $package_checks_requested then "missing" else "not-requested" end)}
      elif ($matches|length) > 1 then
        {status:"ambiguous",accepted:false,file_sha256:$evidence_hash,package_verification:(if $package_checks_requested then "ambiguous" else "not-requested" end)}
      else
        ($matches[0]) as $row |
        (try ($row.bht_completed_at|fromdateiso8601) catch null) as $completed_epoch |
        (($row.bht_patterns // []) | map(ascii_downcase) | sort) as $patterns |
        (package_verified($row)) as $package_ok |
        (($row.bht_status == "complete") and
         ($row.bht_progress_percent == 100) and
         (($row.bht_errors // [])|length == 0) and
         ($patterns == ["0x00","0x55","0xaa","0xff"]) and
         ($row.smart_passed == true) and
         ($row.grade == "A") and
         ($row.disposition == "passed_monitor") and
         ($row.production_readiness == "ready_sustained_writes_and_casual_reads") and
         ($completed_epoch != null and $completed_epoch <= $now_epoch and (($now_epoch-$completed_epoch) <= ($max_age_days*86400))) and
         (($package_checks_requested|not) or $package_ok)) as $accepted |
        {
          status:(if $accepted then "accepted" else "rejected" end),accepted:$accepted,
          file_sha256:$evidence_hash,server:$row.server,run_id:$row.run_id,
          completed_at:$row.bht_completed_at,grade:$row.grade,confidence:$row.confidence,
          disposition:$row.disposition,source_digest:$row.evidence_source_digest,
          package_verification:(if $package_checks_requested then (if $package_ok then "verified" else "failed" end) else "not-requested" end)
        }
      end;
    .health_policy=$policy |
    .health_evidence={supplied:($evidence_hash != ""),file_sha256:(if $evidence_hash=="" then null else $evidence_hash end),server:(if $evidence_server=="" then null else $evidence_server end),max_age_days:$max_age_days,package_checks_requested:$package_checks_requested} |
    .disks |= map(
      .observed_hctl=normalized_hctl |
      .observed_slot_index=normalized_slot_index |
      .observed_slot_source=normalized_slot_source |
      .observed_slot_scope=normalized_slot_scope |
      .health_policy=$policy |
      .smart_health=smart_state |
      .health_evidence=evidence_record(.) |
      .effective_health=(
        if $policy=="smart-required" then (if .smart_health=="passed" then "passed" else "blocked" end)
        elif $policy=="bht-required" then (if .health_evidence.accepted then "passed" else "blocked" end)
        elif (.smart_health=="passed" or .health_evidence.accepted) then "passed"
        else "advisory" end
      ) |
      .warnings=((.warnings // []) +
        (if .smart_health=="passed" then [] else ["smart-"+.smart_health+"-advisory"] end) +
        (if (.health_evidence.status=="not-supplied" or .health_evidence.status=="accepted") then [] else ["bht-evidence-"+.health_evidence.status] end) | unique) |
      .reasons=((.reasons // []) +
        (if $policy=="smart-required" and .smart_health!="passed" then ["smart-required-"+.smart_health] else [] end) +
        (if $policy=="bht-required" and (.health_evidence.accepted|not) then ["bht-required-"+.health_evidence.status] else [] end) | unique) |
      .eligible=((.reasons|length)==0)
    )
  ' "${inventory}" > "${output}"
  rm -f "${evidence_file}" "${verifications}"
}

zfs.require.root() {
  if zfs.is.true "${PROXMOX_ZFS_TEST_MODE:-0}"; then
    return
  fi
  [[ "${EUID}" -eq 0 ]] || zfs.die "This action must run as root on the local host"
}

zfs.write.atomic() {
  local destination="$1" mode="$2" source="$3" destination_dir temporary
  destination_dir="$(dirname "${destination}")"
  mkdir -p "${destination_dir}"
  temporary="$(mktemp "${destination_dir}/.zfs-feature.XXXXXX")"
  chmod "${mode}" "${temporary}"
  cp "${source}" "${temporary}"
  chmod "${mode}" "${temporary}"
  mv "${temporary}" "${destination}"
}

zfs.canonicalize.file() {
  local source="$1" destination="$2"
  jq -S . "${source}" > "${destination}"
}

zfs.resolve.stable.path() {
  local device="$1" candidate="" resolved="" device_resolved="" best=""
  device_resolved="$(readlink -f "${device}" 2>/dev/null || true)"
  for candidate in /dev/disk/by-id/*; do
    [[ -L "${candidate}" ]] || continue
    [[ "${candidate}" != *-part[0-9]* ]] || continue
    resolved="$(readlink -f "${candidate}" 2>/dev/null || true)"
    if [[ -n "${resolved}" && "${resolved}" == "${device_resolved}" ]]; then
      case "$(basename "${candidate}")" in
        wwn-*) printf '%s\n' "${candidate}"; return 0 ;;
        nvme-eui.*) [[ -z "${best}" ]] && best="${candidate}" ;;
        scsi-*) [[ -z "${best}" || "${best}" == *'/ata-'* ]] && best="${candidate}" ;;
        ata-*) [[ -z "${best}" ]] && best="${candidate}" ;;
      esac
    fi
  done
  [[ -n "${best}" ]] || return 1
  printf '%s\n' "${best}"
}

zfs.device.is.os_backing() {
  local device="$1" root_source="" root_parent="" device_real=""
  root_source="$(findmnt -rn -o SOURCE / 2>/dev/null || true)"
  [[ -n "${root_source}" ]] || return 1
  root_parent="$(lsblk -spno NAME "${root_source}" 2>/dev/null | tail -n 1 || true)"
  device_real="$(readlink -f "${device}" 2>/dev/null || true)"
  [[ -n "${root_parent}" && "${device_real}" == "$(readlink -f "${root_parent}" 2>/dev/null || true)" ]]
}

zfs.device.has.swap() {
  local device="$1" device_real child swap_device
  device_real="$(readlink -f "${device}")"
  command -v swapon >/dev/null 2>&1 || return 1
  while IFS= read -r swap_device; do
    [[ -n "${swap_device}" ]] || continue
    while IFS= read -r child; do
      [[ "$(readlink -f "${child}" 2>/dev/null || true)" == "${device_real}" ]] && return 0
    done < <(lsblk -spno NAME "${swap_device}" 2>/dev/null || true)
  done < <(swapon --noheadings --raw --show=NAME 2>/dev/null || true)
  return 1
}

zfs.device.in.command.output() {
  local device="$1" command_output="$2" device_real child stable child_name
  device_real="$(readlink -f "${device}" 2>/dev/null || true)"
  [[ -n "${device_real}" ]] || return 1
  while IFS= read -r child; do
    [[ -n "${child}" ]] || continue
    if grep -Fq -- "${child}" <<< "${command_output}"; then
      return 0
    fi
    stable="$(zfs.resolve.stable.path "${child}" 2>/dev/null || true)"
    if [[ -n "${stable}" ]] && grep -Fq -- "${stable}" <<< "${command_output}"; then
      return 0
    fi
    child_name="$(basename "${child}")"
    if grep -Eq "(^|[[:space:]/])${child_name}(\\[|[[:space:]]|$)" <<< "${command_output}"; then
      return 0
    fi
  done < <(lsblk -pnro NAME "${device}" 2>/dev/null || true)
  return 1
}

zfs.device.enclosure.slot() {
  local kernel="$1" root="${PROXMOX_ZFS_SYS_ENCLOSURE_ROOT:-/sys/class/enclosure}"
  local candidate slot_dir enclosure_dir slot_value slot_index
  [[ -d "${root}" ]] || return 1
  for candidate in "${root}"/*/*/device/block/"${kernel}"; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    slot_dir="$(dirname "$(dirname "$(dirname "${candidate}")")")"
    enclosure_dir="$(dirname "${slot_dir}")"
    slot_value=""
    if [[ -r "${slot_dir}/slot" ]]; then
      slot_value="$(sed -n '1p' "${slot_dir}/slot" 2>/dev/null || true)"
    fi
    [[ -n "${slot_value}" ]] || slot_value="$(basename "${slot_dir}")"
    if [[ "${slot_value}" =~ ([0-9]+)$ ]]; then
      slot_index="$((10#${BASH_REMATCH[1]}))"
      printf '%s\t%s\n' "enclosure:$(basename "${enclosure_dir}")" "${slot_index}"
      return 0
    fi
  done
  return 1
}

zfs.inventory.collect.live() {
  local lsblk_json row path kernel stable_path smart_json smart_text smart_health smart_parse_quality smartctl_exit_status
  local transport smart_transport signatures_json reasons_json warnings_json
  local descendants mounts holders lvm_output md_output zpool_output ceph_output
  local tmp_rows entry type size rota media model vendor serial wwn ro rm log_sec phy_sec
  local hctl sysfs_path hba enclosure slot fault_domain command_name
  local hctl_host hctl_channel hctl_target hctl_lun slot_metadata
  local observed_slot_index observed_slot_source observed_slot_scope

  for command_name in lsblk findmnt readlink smartctl wipefs blkid swapon pvs mdadm; do
    zfs.require.command "${command_name}"
  done

  lsblk_json="$(lsblk --bytes --json -d -o NAME,KNAME,PATH,TYPE,SIZE,ROTA,TRAN,MODEL,VENDOR,SERIAL,WWN,HCTL,RO,RM,LOG-SEC,PHY-SEC)"
  tmp_rows="$(mktemp)"
  lvm_output="$(pvs --noheadings -o pv_name,pv_tags 2>/dev/null || true)"
  md_output="$(cat /proc/mdstat 2>/dev/null || true)"
  zpool_output="$(zpool status -P 2>/dev/null || true)"
  ceph_output=""
  if command -v ceph-volume >/dev/null 2>&1; then
    ceph_output="$(ceph-volume lvm list --format json 2>/dev/null || true) $(ceph-volume raw list --format json 2>/dev/null || true)"
  fi

  while IFS= read -r row; do
    type="$(jq -r '.type // ""' <<< "${row}")"
    [[ "${type}" == "disk" ]] || continue
    path="$(jq -r '.path' <<< "${row}")"
    kernel="$(jq -r '.kname // .name' <<< "${row}")"
    size="$(jq -r '.size // 0' <<< "${row}")"
    rota="$(jq -r '.rota // false' <<< "${row}")"
    model="$(jq -r '.model // ""' <<< "${row}" | sed 's/[[:space:]]*$//')"
    vendor="$(jq -r '.vendor // ""' <<< "${row}" | sed 's/[[:space:]]*$//')"
    serial="$(jq -r '.serial // ""' <<< "${row}" | sed 's/[[:space:]]*$//')"
    wwn="$(jq -r '.wwn // ""' <<< "${row}" | sed 's/[[:space:]]*$//')"
    ro="$(jq -r '.ro // false' <<< "${row}")"
    rm="$(jq -r '.rm // false' <<< "${row}")"
    log_sec="$(jq -r '.["log-sec"] // 0' <<< "${row}")"
    phy_sec="$(jq -r '.["phy-sec"] // 0' <<< "${row}")"
    hctl="$(jq -r '.hctl // ""' <<< "${row}")"
    transport="$(jq -r '.tran // ""' <<< "${row}" | tr '[:upper:]' '[:lower:]')"
    stable_path="$(zfs.resolve.stable.path "${path}" 2>/dev/null || true)"
    if [[ "${rota}" == "true" || "${rota}" == "1" ]]; then media="hdd"; else media="ssd"; fi
    sysfs_path="$(readlink -f "/sys/class/block/${kernel}/device" 2>/dev/null || true)"
    hba=""; hctl_host=""; hctl_channel=""; hctl_target=""; hctl_lun=""
    if [[ "${hctl}" =~ ^([0-9]+):([0-9]+):([0-9]+):([0-9]+)$ ]]; then
      hctl_host="${BASH_REMATCH[1]}"; hctl_channel="${BASH_REMATCH[2]}"
      hctl_target="${BASH_REMATCH[3]}"; hctl_lun="${BASH_REMATCH[4]}"
      hba="host${hctl_host}"
    fi
    enclosure=""
    if [[ -n "${sysfs_path}" ]]; then enclosure="$(basename "$(dirname "${sysfs_path}")")"; fi
    slot="${hctl}"
    observed_slot_index="null"; observed_slot_source=""; observed_slot_scope=""
    slot_metadata="$(zfs.device.enclosure.slot "${kernel}" 2>/dev/null || true)"
    if [[ -n "${slot_metadata}" ]]; then
      observed_slot_scope="${slot_metadata%%$'\t'*}"
      observed_slot_index="${slot_metadata#*$'\t'}"
      observed_slot_source="sysfs-enclosure-slot"
    elif [[ -n "${hctl_target}" ]]; then
      observed_slot_index="$((10#${hctl_target}))"
      observed_slot_source="scsi-hctl-target"
      observed_slot_scope="host${hctl_host}:channel${hctl_channel}"
    fi
    fault_domain="${hba:-unknown}:${enclosure:-unknown}:${slot:-unknown}"

    smartctl_exit_status=0
    if smart_json="$(smartctl -i -H -j "${path}" 2>/dev/null)"; then
      smartctl_exit_status=0
    else
      smartctl_exit_status=$?
    fi
    [[ -n "${smart_json}" ]] || smart_json='{}'
    smart_text="$(smartctl -i "${path}" 2>/dev/null || true)"
    if [[ -z "${serial}" ]]; then serial="$(jq -r '.serial_number // ""' <<< "${smart_json}" 2>/dev/null || true)"; fi
    if [[ -z "${wwn}" && "${stable_path}" == /dev/disk/by-id/wwn-* ]]; then wwn="${stable_path##*/wwn-}"; fi
    smart_health="$(zfs.health.smart.normalize "${smart_json}")"
    smart_parse_quality="invalid"
    if jq -e -s 'length==1 and (.[0]|type=="object")' >/dev/null 2>&1 <<< "${smart_json}"; then smart_parse_quality="valid"; fi
    smart_transport=""
    if grep -Eqi 'Transport protocol:[[:space:]]*SAS|SAS transport' <<< "${smart_text}"; then
      smart_transport="sas"
    fi
    if [[ -z "${transport}" && -n "${smart_transport}" ]]; then
      transport="${smart_transport}"
    fi

    signatures_json="$(wipefs -n -J "${path}" 2>/dev/null | jq -c '[.signatures[]? | (.type // .usage // "unknown")] | unique' 2>/dev/null || printf '[]')"
    descendants="$(lsblk -pnro NAME,TYPE "${path}" 2>/dev/null | tail -n +2 || true)"
    mounts="$(lsblk -pnro MOUNTPOINT "${path}" 2>/dev/null | awk 'NF' || true)"
    holders="$(find "/sys/class/block/${kernel}/holders" -mindepth 1 -maxdepth 1 -print 2>/dev/null || true)"
    reasons_json='[]'
    warnings_json='[]'

    [[ -n "${stable_path}" ]] || reasons_json="$(jq -c '. + ["missing-stable-by-id"]' <<< "${reasons_json}")"
    [[ -n "${wwn}" ]] || reasons_json="$(jq -c '. + ["missing-wwn"]' <<< "${reasons_json}")"
    [[ -n "${serial}" ]] || reasons_json="$(jq -c '. + ["missing-serial"]' <<< "${reasons_json}")"
    case "${transport}" in sas|sata|scsi|nvme|usb) ;; *) reasons_json="$(jq -c '. + ["missing-or-unsupported-transport"]' <<< "${reasons_json}")" ;; esac
    [[ "${size}" =~ ^[1-9][0-9]*$ ]] || reasons_json="$(jq -c '. + ["missing-size"]' <<< "${reasons_json}")"
    [[ "${log_sec}" =~ ^[1-9][0-9]*$ ]] || reasons_json="$(jq -c '. + ["missing-logical-sector-size"]' <<< "${reasons_json}")"
    [[ "${phy_sec}" =~ ^[1-9][0-9]*$ ]] || reasons_json="$(jq -c '. + ["missing-physical-sector-size"]' <<< "${reasons_json}")"
    [[ "${ro}" != "true" && "${ro}" != "1" ]] || reasons_json="$(jq -c '. + ["read-only"]' <<< "${reasons_json}")"
    [[ "${rm}" != "true" && "${rm}" != "1" ]] || reasons_json="$(jq -c '. + ["removable"]' <<< "${reasons_json}")"
    [[ -z "${descendants}" ]] || reasons_json="$(jq -c '. + ["contains-partitions-or-children"]' <<< "${reasons_json}")"
    [[ -z "${mounts}" ]] || reasons_json="$(jq -c '. + ["mounted-filesystem"]' <<< "${reasons_json}")"
    [[ -z "${holders}" ]] || reasons_json="$(jq -c '. + ["device-holders"]' <<< "${reasons_json}")"
    if zfs.device.is.os_backing "${path}"; then reasons_json="$(jq -c '. + ["os-or-boot-device"]' <<< "${reasons_json}")"; fi
    if zfs.device.has.swap "${path}"; then reasons_json="$(jq -c '. + ["active-swap"]' <<< "${reasons_json}")"; fi
    if zfs.device.in.command.output "${path}" "${lvm_output}"; then reasons_json="$(jq -c '. + ["active-lvm"]' <<< "${reasons_json}")"; fi
    if zfs.device.in.command.output "${path}" "${md_output}"; then reasons_json="$(jq -c '. + ["active-mdraid"]' <<< "${reasons_json}")"; fi
    if zfs.device.in.command.output "${path}" "${zpool_output}"; then reasons_json="$(jq -c '. + ["imported-zfs-member"]' <<< "${reasons_json}")"; fi
    if [[ -n "${ceph_output}" ]] && zfs.device.in.command.output "${path}" "${ceph_output}"; then reasons_json="$(jq -c '. + ["active-ceph"]' <<< "${reasons_json}")"; fi
    [[ "${smart_health}" == "passed" ]] || warnings_json="$(jq -c --arg warning "smart-${smart_health}-advisory" '. + [$warning]' <<< "${warnings_json}")"
    if [[ -n "${smart_transport}" && -n "${transport}" && "${transport}" != "${smart_transport}" ]]; then
      reasons_json="$(jq -c '. + ["transport-conflict"]' <<< "${reasons_json}")"
    fi
    if [[ "$(jq 'length' <<< "${signatures_json}")" -gt 0 ]]; then
      warnings_json="$(jq -c '. + ["signatures-present"]' <<< "${warnings_json}")"
    fi

    entry="$(jq -n -c \
      --arg kernel "${kernel}" --arg path "${path}" --arg stable_path "${stable_path}" \
      --arg wwn "${wwn}" --arg serial "${serial}" --arg model "${model}" --arg vendor "${vendor}" \
      --arg transport "${transport}" --arg media "${media}" --arg smart_health "${smart_health}" --arg smart_parse_quality "${smart_parse_quality}" \
      --arg hba "${hba}" --arg enclosure "${enclosure}" --arg slot "${slot}" --arg observed_hctl "${hctl}" \
      --arg observed_slot_source "${observed_slot_source}" --arg observed_slot_scope "${observed_slot_scope}" \
      --arg sysfs_path "${sysfs_path}" --arg fault_domain "${fault_domain}" \
      --argjson size_bytes "${size}" --argjson rotational "${rota}" --argjson smartctl_exit_status "${smartctl_exit_status}" \
      --argjson logical_sector_bytes "${log_sec}" --argjson physical_sector_bytes "${phy_sec}" \
      --argjson observed_slot_index "${observed_slot_index}" \
      --argjson signatures "${signatures_json}" --argjson reasons "${reasons_json}" --argjson warnings "${warnings_json}" \
      '{kernel:$kernel,path:$path,stable_path:$stable_path,wwn:$wwn,serial:$serial,model:$model,vendor:$vendor,transport:$transport,media:$media,size_bytes:$size_bytes,rotational:$rotational,logical_sector_bytes:$logical_sector_bytes,physical_sector_bytes:$physical_sector_bytes,smart_health:$smart_health,smart_parse_quality:$smart_parse_quality,smartctl_exit_status:$smartctl_exit_status,hba:$hba,enclosure:$enclosure,slot:$slot,observed_hctl:$observed_hctl,observed_slot_index:$observed_slot_index,observed_slot_source:$observed_slot_source,observed_slot_scope:$observed_slot_scope,sysfs_path:$sysfs_path,fault_domain:$fault_domain,whole_disk:true,signatures:$signatures,reasons:$reasons,warnings:$warnings,eligible:($reasons|length==0)}')"
    printf '%s\n' "${entry}" >> "${tmp_rows}"
  done < <(jq -c '.blockdevices[]?' <<< "${lsblk_json}")

  jq -s '{schema_version:1,disks:sort_by(if .observed_slot_index==null then 1 else 0 end,.observed_slot_scope,.observed_slot_index,.stable_path,.kernel)}' "${tmp_rows}"
  rm -f "${tmp_rows}"
}

zfs.inventory.collect() {
  local policy="${1:-${ZFS_DEFAULT_HEALTH_POLICY}}" evidence="${2:-}" evidence_root="${3:-}" evidence_server="${4:-}" max_age_days="${5:-${ZFS_DEFAULT_HEALTH_EVIDENCE_AGE_DAYS}}" raw processed
  zfs.require.base.commands
  raw="$(mktemp)"
  processed="$(mktemp)"
  if [[ -n "${PROXMOX_ZFS_INVENTORY_FIXTURE:-}" ]]; then
    [[ -r "${PROXMOX_ZFS_INVENTORY_FIXTURE}" ]] || zfs.die "Inventory fixture is unreadable"
    jq -S . "${PROXMOX_ZFS_INVENTORY_FIXTURE}" > "${raw}"
  else
    zfs.inventory.collect.live > "${raw}"
  fi
  zfs.inventory.apply.health "${raw}" "${processed}" "${policy}" "${evidence}" "${evidence_root}" "${evidence_server}" "${max_age_days}"
  cat "${processed}"
  rm -f "${raw}" "${processed}"
}

zfs.inventory.print.table() {
  local inventory="$1"
  if command -v column >/dev/null 2>&1; then
    jq -r '
    def human: if .>=1099511627776 then (((./1099511627776)*100|round)/100|tostring)+"TiB" elif .>=1073741824 then (((./1073741824)*100|round)/100|tostring)+"GiB" else (tostring)+"B" end;
    ["INDEX","DEVICE","BY-ID","SERIAL","MODEL","TYPE","MEDIA","SIZE","SIZE_BYTES","SLOT","SLOT_SOURCE","SMART","HEALTH","BHT","DOMAIN","SIGNATURES","ELIGIBLE","REASON"],
    (.disks | to_entries[] | [
      (.key+1), .value.path, (.value.stable_path // "-"), (.value.serial // "-"),
      (.value.model // "-"), (.value.transport // "-"), (.value.media // (if .value.rotational then "hdd" else "ssd" end)), (.value.size_bytes|human), .value.size_bytes,
      (.value.observed_slot_index // "-"), (.value.observed_slot_source // "-"),
      (.value.smart_health // "unknown"), (.value.effective_health // "advisory"), (.value.health_evidence.status // "not-supplied"), (.value.fault_domain // "unknown"), (.value.signatures|join(",")),
      .value.eligible, ((.value.reasons + .value.warnings)|join(","))
    ]) | @tsv' "${inventory}" | column -t -s $'\t'
  else
    jq -r '
      def human: if .>=1099511627776 then (((./1099511627776)*100|round)/100|tostring)+"TiB" elif .>=1073741824 then (((./1073741824)*100|round)/100|tostring)+"GiB" else (tostring)+"B" end;
      ["INDEX","DEVICE","BY-ID","SERIAL","MODEL","TYPE","MEDIA","SIZE","SIZE_BYTES","SLOT","SLOT_SOURCE","SMART","HEALTH","BHT","DOMAIN","SIGNATURES","ELIGIBLE","REASON"],
      (.disks | to_entries[] | [
        (.key+1), .value.path, (.value.stable_path // "-"), (.value.serial // "-"),
        (.value.model // "-"), (.value.transport // "-"), (.value.media // (if .value.rotational then "hdd" else "ssd" end)), (.value.size_bytes|human), .value.size_bytes,
        (.value.observed_slot_index // "-"), (.value.observed_slot_source // "-"),
        (.value.smart_health // "unknown"), (.value.effective_health // "advisory"), (.value.health_evidence.status // "not-supplied"), (.value.fault_domain // "unknown"), (.value.signatures|join(",")),
        .value.eligible, ((.value.reasons + .value.warnings)|join(","))
      ]) | @tsv' "${inventory}"
  fi
}

zfs.size.to.bytes() {
  local input="$1" number suffix normalized multiplier
  if [[ "${input}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${input}"
    return
  fi
  if [[ ! "${input}" =~ ^([0-9]+([.][0-9]+)?)([bB]|[KMGTPEkmgtpe]([iI])?[bB])$ ]]; then
    zfs.die "Invalid or ambiguous size: ${input}; use bytes or an explicit unit such as 6TB or 5.5TiB"
  fi
  number="${BASH_REMATCH[1]}"
  suffix="${BASH_REMATCH[3]}"
  normalized="$(tr '[:upper:]' '[:lower:]' <<< "${suffix}")"
  case "${normalized}" in
    b) multiplier=1 ;;
    kb) multiplier=1000 ;;
    mb) multiplier=1000000 ;;
    gb) multiplier=1000000000 ;;
    tb) multiplier=1000000000000 ;;
    pb) multiplier=1000000000000000 ;;
    eb) multiplier=1000000000000000000 ;;
    kib) multiplier=1024 ;;
    mib) multiplier=1048576 ;;
    gib) multiplier=1073741824 ;;
    tib) multiplier=1099511627776 ;;
    pib) multiplier=1125899906842624 ;;
    eib) multiplier=1152921504606846976 ;;
    *) zfs.die "Unsupported size suffix: ${input}" ;;
  esac
  awk -v number="${number}" -v multiplier="${multiplier}" 'BEGIN { printf "%.0f\n", number * multiplier }'
}

zfs.config.usage() {
  cat <<'EOF'
Usage:
  setup/storage/zpool.config.sh [options]
  setup/storage/zfs.sh configure [options]

Discovers local disks, confirms selections, and writes an editable zpool.config.

Options:
  --pool NAME                         Pool name (default: zfspool)
  --vdev-type TYPE                   mirror, raidz1, raidz2, or raidz3
  --vdev-count NUMBER                Number of equal-width data vdevs
  --drives-per-vdev NUMBER           Devices in each data vdev
  --type TYPE                        sas, sata, scsi, nvme, usb, or any
  --media TYPE                       hdd, ssd, or any
  --size SIZE                        Exact-unit filter, e.g. 6TB or 5.5TiB
  --size-tolerance-percent NUMBER    Size range and identity tolerance (default: 1)
  --model MODEL                      Filter by exact normalized model (repeatable)
  --serial SOURCE                    Ordered serial, [SERIAL,...], or one-per-line file
  --device IDENTIFIER                Select an exact disk (repeatable)
  --avoid IDENTIFIER                 Exclude exact path/by-id/WWN/serial (repeatable)
  --device-order MODE                auto (default), slot, selection, or stable-path
  --health-policy POLICY             advisory (default), smart-required, or bht-required
  --health-evidence FILE             Optional BHT offline drive reference JSON
  --health-evidence-root DIRECTORY   Optionally verify referenced evidence packages
  --evidence-server NAME             Scope BHT evidence rows to a server
  --max-health-evidence-age-days N   Evidence freshness limit (default: 30)
  --all-matches                      Select every eligible filtered candidate
  --non-interactive                  Require deterministic selection/topology flags
  --review-format FORMAT             pretty-json (default) or table
  --dataset POOL/DATASET             Dataset (default: <pool>/archive)
  --mountpoint PATH                  Dataset mountpoint (default: /media/<dataset>)
  --allow-signature-wipe             Permit a separate reviewed wipe plan
  --config PATH                      Output path (default: ./zpool.config)
  --replace                          Back up and replace an existing config
  --install-deps                     Explicitly install required Debian packages
  -h, --help                         Show this help

Interactive selection asks y/n/all/none for each eligible candidate. The size
filter is stored as explicit byte bounds; each disk's expected_size_bytes,
WWN, serial, transport, slot evidence, and sector sizes remain authoritative.
EOF
}

zfs.prompt() {
  local prompt="$1" default="${2:-}" answer=""
  if [[ -n "${default}" ]]; then
    printf '%s [%s]: ' "${prompt}" "${default}" >/dev/tty
  else
    printf '%s: ' "${prompt}" >/dev/tty
  fi
  IFS= read -r answer </dev/tty || true
  printf '%s\n' "${answer:-${default}}"
}

zfs.config.safe.output() {
  local output="$1" output_dir mode
  output_dir="$(cd "$(dirname "${output}")" 2>/dev/null && pwd -P)" || zfs.die "Configuration directory does not exist: $(dirname "${output}")"
  case "${output_dir}" in
    /|/tmp|/var/tmp|/private/tmp) zfs.die "Refusing to write configuration in unsafe directory: ${output_dir}" ;;
  esac
  [[ -w "${output_dir}" ]] || zfs.die "Configuration directory is not writable: ${output_dir}"
  [[ ! -L "${output}" ]] || zfs.die "Refusing symlink output: ${output}"
  mode="$(stat -c '%a' "${output_dir}" 2>/dev/null || stat -f '%Lp' "${output_dir}" 2>/dev/null || printf 777)"
  if (( (8#${mode}) & 0002 )); then
    zfs.die "Refusing world-writable output directory: ${output_dir}"
  fi
}

zfs.identifier.filter() {
  local inventory="$1" identifier="$2"
  jq -c --arg identifier "${identifier}" '
    [.disks[] | select(
      .path == $identifier or .stable_path == $identifier or
      .wwn == $identifier or .serial == $identifier or .kernel == $identifier
    )]' "${inventory}"
}

zfs.serial.selection.read() {
  local source="$1" parsed="" item=""
  local -a serial_array=()
  if [[ -f "${source}" ]]; then
    [[ -r "${source}" ]] || zfs.die "Serial selection file is unreadable: ${source}"
    if jq -e 'type=="array" and length>0 and all(.[];type=="string" and length>0)' "${source}" >/dev/null 2>&1; then
      parsed="$(jq -r '.[]' "${source}")"
    else
      parsed="$(awk '
        { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
        length > 0 && substr($0,1,1) != "#" { print }
      ' "${source}")"
    fi
    [[ -n "${parsed}" ]] || zfs.die "Serial selection file contains no serials: ${source}"
    printf '%s\n' "${parsed}"
    return
  fi
  if [[ "${source}" == \[*\] ]]; then
    if parsed="$(jq -er 'if type=="array" and length>0 and all(.[];type=="string" and length>0) then .[] else error("invalid serial array") end' <<< "${source}" 2>/dev/null)"; then
      printf '%s\n' "${parsed}"
      return
    fi
    source="${source#\[}"
    source="${source%\]}"
    IFS=',' read -r -a serial_array <<< "${source}"
    ((${#serial_array[@]} > 0)) || zfs.die "Serial array is empty"
    for item in "${serial_array[@]}"; do
      item="$(awk '{$1=$1; print}' <<< "${item}")"
      [[ -n "${item}" && "${item}" != *'['* && "${item}" != *']'* ]] || zfs.die "Invalid serial array entry"
      printf '%s\n' "${item}"
    done
    return
  fi
  [[ -n "${source}" ]] || zfs.die "Serial selection cannot be empty"
  printf '%s\n' "${source}"
}

zfs.vdev.minimum.width() {
  case "$1" in
    mirror) printf '2\n' ;;
    raidz1) printf '3\n' ;;
    raidz2) printf '4\n' ;;
    raidz3) printf '5\n' ;;
    *) return 1 ;;
  esac
}

zfs.config.validate.topology.args() {
  local pool="$1" vdev_type="$2" vdev_count="$3" per_vdev="$4" selected_count="$5" minimum
  [[ "${pool}" =~ ^[A-Za-z][A-Za-z0-9_.:-]*$ ]] || zfs.die "Invalid ZFS pool name: ${pool}"
  minimum="$(zfs.vdev.minimum.width "${vdev_type}" 2>/dev/null || true)"
  [[ -n "${minimum}" ]] || zfs.die "Unsupported data vdev type: ${vdev_type}"
  [[ "${vdev_count}" =~ ^[1-9][0-9]*$ ]] || zfs.die "Vdev count must be a positive integer"
  [[ "${per_vdev}" =~ ^[1-9][0-9]*$ ]] || zfs.die "Drives per vdev must be a positive integer"
  ((per_vdev >= minimum)) || zfs.die "${vdev_type} requires at least ${minimum} devices per vdev"
  ((vdev_count * per_vdev == selected_count)) || zfs.die "Selected ${selected_count} devices, but topology requires $((vdev_count * per_vdev))"
}

zfs.config.review.json() {
  local inventory="$1" candidates="$2" transport="$3" media="$4"
  local size_filter="$5" models="$6" avoided="$7"
  jq -n -S \
    --argjson inventory "${inventory}" --argjson candidates "${candidates}" \
    --arg transport "${transport}" --arg media "${media}" \
    --argjson size_filter "${size_filter}" --argjson models "${models}" --argjson avoided "${avoided}" '
    def disk_record($disk; $index): {
      index:$index,
      path:$disk.path,
      stable_path:$disk.stable_path,
      serial:$disk.serial,
      wwn:$disk.wwn,
      model:$disk.model,
      transport:$disk.transport,
      media:($disk.media // (if $disk.rotational then "hdd" else "ssd" end)),
      size_bytes:$disk.size_bytes,
      logical_sector_bytes:$disk.logical_sector_bytes,
      physical_sector_bytes:$disk.physical_sector_bytes,
      smart_health:($disk.smart_health // "unknown"),
      effective_health:($disk.effective_health // "advisory"),
      health_evidence_status:($disk.health_evidence.status // "not-supplied"),
      observed_hctl:($disk.observed_hctl // ""),
      observed_slot_index:($disk.observed_slot_index // null),
      observed_slot_source:($disk.observed_slot_source // ""),
      observed_slot_scope:($disk.observed_slot_scope // ""),
      fault_domain:($disk.fault_domain // "unknown"),
      signatures:($disk.signatures // []),
      eligible:$disk.eligible,
      reasons:($disk.reasons // []),
      warnings:($disk.warnings // [])
    };
    ($candidates | map(.stable_path)) as $candidate_paths |
    ($inventory.disks | map(. as $disk | select(($candidate_paths | index($disk.stable_path)) == null))) as $excluded |
    {
      schema_version:1,
      review_kind:"zfs-device-selection",
      filters:{
        transport:(if $transport == "any" then null else $transport end),
        media:(if $media == "any" then null else $media end),
        size_bytes:$size_filter,
        models:$models,
        avoided:$avoided
      },
      summary:{
        discovered_count:($inventory.disks | length),
        candidate_count:($candidates | length),
        excluded_count:($excluded | length),
        ineligible_count:([$excluded[] | select(.eligible != true)] | length),
        filtered_count:([$excluded[] | select(.eligible == true)] | length)
      },
      candidates:[
        $candidates | to_entries[] |
        disk_record(.value; (.key + 1)) + {selection_status:"candidate"}
      ],
      excluded:[
        $excluded | to_entries[] |
        .value as $disk |
        disk_record($disk; (.key + 1)) + {
          selection_status:(if $disk.eligible == true then "filtered-out" else "ineligible" end),
          selection_reasons:((if $disk.eligible == true then ["filtered-out"] else [] end) + ($disk.reasons // []) + ($disk.warnings // []))
        }
      ]
    }'
}

zfs.config.review.print() {
  local inventory="$1" candidates="$2" transport="$3" media="$4"
  local size_filter="$5" models="$6" avoided="$7" review_format="$8" tmp
  case "${review_format}" in
    pretty-json)
      zfs.config.review.json "${inventory}" "${candidates}" "${transport}" "${media}" \
        "${size_filter}" "${models}" "${avoided}"
      ;;
    table)
      tmp="$(mktemp)"
      printf '%s\n' "${inventory}" > "${tmp}"
      zfs.inventory.print.table "${tmp}"
      rm -f "${tmp}"
      ;;
    *) zfs.die "Review format must be pretty-json or table" ;;
  esac
}

zfs.config.candidate.review.json() {
  local item="$1" index="$2" total="$3"
  jq -n -S --argjson device "${item}" --argjson index "${index}" --argjson total "${total}" '
    {
      review_kind:"zfs-device-candidate",
      candidate_index:$index,
      candidate_count:$total,
      device:{
        path:$device.path,
        stable_path:$device.stable_path,
        serial:$device.serial,
        wwn:$device.wwn,
        model:$device.model,
        transport:$device.transport,
        media:($device.media // (if $device.rotational then "hdd" else "ssd" end)),
        size_bytes:$device.size_bytes,
        logical_sector_bytes:$device.logical_sector_bytes,
        physical_sector_bytes:$device.physical_sector_bytes,
        smart_health:($device.smart_health // "unknown"),
        effective_health:($device.effective_health // "advisory"),
        health_evidence_status:($device.health_evidence.status // "not-supplied"),
        observed_hctl:($device.observed_hctl // ""),
        observed_slot_index:($device.observed_slot_index // null),
        observed_slot_source:($device.observed_slot_source // ""),
        observed_slot_scope:($device.observed_slot_scope // ""),
        fault_domain:($device.fault_domain // "unknown"),
        signatures:($device.signatures // []),
        eligible:$device.eligible,
        reasons:($device.reasons // []),
        warnings:($device.warnings // [])
      }
    }'
}

zfs.config.selected.order.review.json() {
  local selected="$1"
  jq -n -S --argjson selected "${selected}" '
    {
      review_kind:"zfs-selected-device-order",
      selected_count:($selected | length),
      devices:[
        $selected | to_entries[] | {
          order:(.key + 1),
          stable_path:.value.stable_path,
          serial:.value.serial,
          wwn:.value.wwn,
          observed_slot_index:(.value.observed_slot_index // null),
          observed_slot_source:(.value.observed_slot_source // ""),
          observed_slot_scope:(.value.observed_slot_scope // ""),
          observed_hctl:(.value.observed_hctl // ""),
          fault_domain:(.value.fault_domain // "unknown")
        }
      ]
    }'
}

zfs.config.choose.interactive() {
  local candidates="$1" selected='[]' item answer include_rest=0 exclude_rest=0 index=0 total
  total="$(jq 'length' <<< "${candidates}")"
  while IFS= read -r item; do
    index="$((index + 1))"
    if ((exclude_rest == 1)); then continue; fi
    if ((include_rest == 1)); then
      selected="$(jq -c --argjson item "${item}" '. + [$item]' <<< "${selected}")"
      continue
    fi
    zfs.config.candidate.review.json "${item}" "${index}" "${total}" >&2
    while true; do
      answer="$(zfs.prompt "Include candidate ${index}/${total}? [y/n/all/none]" "n")"
      case "$(tr '[:upper:]' '[:lower:]' <<< "${answer}")" in
        y|yes) selected="$(jq -c --argjson item "${item}" '. + [$item]' <<< "${selected}")"; break ;;
        n|no) break ;;
        all) selected="$(jq -c --argjson item "${item}" '. + [$item]' <<< "${selected}")"; include_rest=1; break ;;
        none) exclude_rest=1; break ;;
        *) printf 'Enter y, n, all, or none.\n' >/dev/tty ;;
      esac
    done
  done < <(jq -c '.[]' <<< "${candidates}")
  printf '%s\n' "${selected}"
}

zfs.config.reorder.by.indexes() {
  local selected="$1" response="$2" item index reordered='[]' seen='[]'
  local -a selected_indexes=()
  IFS=',' read -r -a selected_indexes <<< "${response}"
  [[ "${#selected_indexes[@]}" -eq "$(jq 'length' <<< "${selected}")" ]] || zfs.die "Reordering must include every selected index exactly once"
  for index in "${selected_indexes[@]}"; do
    index="${index//[[:space:]]/}"
    [[ "${index}" =~ ^[1-9][0-9]*$ ]] || zfs.die "Invalid reorder index: ${index}"
    jq -e --argjson index "${index}" 'index($index) == null' <<< "${seen}" >/dev/null || zfs.die "Reordering contains duplicate indexes"
    item="$(jq -c --argjson index "$((index - 1))" '.[$index] // empty' <<< "${selected}")"
    [[ -n "${item}" ]] || zfs.die "Reorder index is out of range: ${index}"
    reordered="$(jq -c --argjson item "${item}" '. + [$item]' <<< "${reordered}")"
    seen="$(jq -c --argjson index "${index}" '. + [$index]' <<< "${seen}")"
  done
  printf '%s\n' "${reordered}"
}

zfs.config.reorder.interactive() {
  local selected="$1" require_override="${2:-0}" response reordered
  printf '\n' >&2
  zfs.config.selected.order.review.json "${selected}" >&2
  response="$(zfs.prompt "Ordered indexes as CSV (Enter keeps this order)" "")"
  if [[ -z "${response}" ]]; then
    ((require_override == 0)) || zfs.die "Automatic slot ordering is ambiguous; enter a complete CSV order or rerun with an explicit --device-order mode"
    jq -n -c --argjson devices "${selected}" '{devices:$devices,overridden:false}'
    return
  fi
  reordered="$(zfs.config.reorder.by.indexes "${selected}" "${response}")"
  jq -n -c --argjson devices "${reordered}" '{devices:$devices,overridden:true}'
}

zfs.config.slot.order.valid() {
  local selected="$1"
  jq -e '
    length>0 and
    all(.[];
      (.observed_slot_index|type)=="number" and
      (.observed_slot_index|floor)==.observed_slot_index and .observed_slot_index>=0 and
      ((.observed_slot_source // "")|type)=="string" and ((.observed_slot_source // "")|length)>0 and
      ((.observed_slot_scope // "")|type)=="string" and ((.observed_slot_scope // "")|length)>0
    ) and
    ([.[].observed_slot_index]|length)==([.[].observed_slot_index]|unique|length) and
    ([.[].observed_slot_source]|unique|length)==1 and
    ([.[].observed_slot_scope]|unique|length)==1
  ' <<< "${selected}" >/dev/null
}

zfs.config.order.resolve() {
  local selected="$1" requested="$2" explicit_selection="$3" ordered source
  case "${requested}" in
    selection)
      jq -n -c --arg requested "${requested}" --argjson devices "${selected}" \
        '{devices:$devices,requested:$requested,effective:"selection",source:"operator-selection",requires_manual:false}'
      ;;
    stable-path)
      ordered="$(jq -c 'sort_by(.stable_path,.kernel)' <<< "${selected}")"
      jq -n -c --arg requested "${requested}" --argjson devices "${ordered}" \
        '{devices:$devices,requested:$requested,effective:"stable-path",source:"stable-path",requires_manual:false}'
      ;;
    slot)
      zfs.config.slot.order.valid "${selected}" || zfs.die "Slot ordering requires one unambiguous scope/source and a unique non-negative numeric slot for every selected disk"
      ordered="$(jq -c 'sort_by(.observed_slot_index,.stable_path)' <<< "${selected}")"
      source="$(jq -r '.[0].observed_slot_source' <<< "${ordered}")"
      jq -n -c --arg requested "${requested}" --arg source "${source}" --argjson devices "${ordered}" \
        '{devices:$devices,requested:$requested,effective:"slot",source:$source,requires_manual:false}'
      ;;
    auto)
      if ((explicit_selection == 1)); then
        jq -n -c --arg requested "${requested}" --argjson devices "${selected}" \
          '{devices:$devices,requested:$requested,effective:"selection",source:"explicit-identifiers",requires_manual:false}'
      elif zfs.config.slot.order.valid "${selected}"; then
        ordered="$(jq -c 'sort_by(.observed_slot_index,.stable_path)' <<< "${selected}")"
        source="$(jq -r '.[0].observed_slot_source' <<< "${ordered}")"
        jq -n -c --arg requested "${requested}" --arg source "${source}" --argjson devices "${ordered}" \
          '{devices:$devices,requested:$requested,effective:"slot",source:$source,requires_manual:false}'
      else
        zfs.warn "Automatic slot ordering is ambiguous; a complete interactive CSV order or explicit --device-order mode is required"
        jq -n -c --arg requested "${requested}" --argjson devices "${selected}" \
          '{devices:$devices,requested:$requested,effective:"manual-required",source:"ambiguous-slot-metadata",requires_manual:true}'
      fi
      ;;
    *) zfs.die "Device order must be auto, slot, selection, or stable-path" ;;
  esac
}

zfs.config.build() {
  local pool="${ZFS_DEFAULT_POOL}" vdev_type="" vdev_count="" per_vdev="" transport="any" media="any"
  local device_order="${ZFS_DEFAULT_DEVICE_ORDER}" order_requested order_effective order_source order_requires_manual
  local requested_size="" tolerance="${ZFS_DEFAULT_SIZE_TOLERANCE_PERCENT}"
  local health_policy="${ZFS_DEFAULT_HEALTH_POLICY}" health_evidence="" health_evidence_root="" evidence_server=""
  local max_health_evidence_age_days="${ZFS_DEFAULT_HEALTH_EVIDENCE_AGE_DAYS}"
  local dataset="" mountpoint="" review_format="${ZFS_DEFAULT_REVIEW_FORMAT}" all_matches=0 non_interactive=0 allow_signature_wipe=0
  local replace=0 inventory_file="" inventory candidates selected requested_bytes=0
  local lower_requested=0 upper_requested=0 candidate_count output="$(pwd -P)/zpool.config" tmp canonical
  local identifier matches match match_count response config_json grouped_json duplicate_count signature_count parsed_serials
  local order_result reorder_result
  local avoid_json='[]' serial_json='[]' model_json='[]' device_count=0 serial_count=0 selected_count interactive=0 explicit_selection=0 filter_size_json='null'
  local health_json topology_advisories_json observed_hbas_json
  local -a avoid_identifiers device_identifiers serial_identifiers model_filters
  avoid_identifiers=()
  device_identifiers=()
  serial_identifiers=()
  model_filters=()

  while (($#)); do
    case "$1" in
      --pool) pool="${2:?missing --pool value}"; shift 2 ;;
      --vdev-type|--raidz) vdev_type="${2:?missing --vdev-type value}"; shift 2 ;;
      --vdev-count|--vdevs) vdev_count="${2:?missing --vdev-count value}"; shift 2 ;;
      --drives-per-vdev) per_vdev="${2:?missing --drives-per-vdev value}"; shift 2 ;;
      --type) transport="$(tr '[:upper:]' '[:lower:]' <<< "${2:?missing --type value}")"; shift 2 ;;
      --media) media="$(tr '[:upper:]' '[:lower:]' <<< "${2:?missing --media value}")"; shift 2 ;;
      --size) requested_size="${2:?missing --size value}"; shift 2 ;;
      --size-tolerance-percent) tolerance="${2:?missing tolerance value}"; shift 2 ;;
      --model) model_filters+=("${2:?missing --model value}"); shift 2 ;;
      --serial)
        parsed_serials="$(zfs.serial.selection.read "${2:?missing --serial value}")"
        while IFS= read -r identifier; do [[ -z "${identifier}" ]] || serial_identifiers+=("${identifier}"); done <<< "${parsed_serials}"
        shift 2
        ;;
      --serial=*)
        parsed_serials="$(zfs.serial.selection.read "${1#*=}")"
        while IFS= read -r identifier; do [[ -z "${identifier}" ]] || serial_identifiers+=("${identifier}"); done <<< "${parsed_serials}"
        shift
        ;;
      --device) device_identifiers+=("${2:?missing --device value}"); shift 2 ;;
      --avoid) avoid_identifiers+=("${2:?missing --avoid value}"); shift 2 ;;
      --device-order) device_order="$(tr '[:upper:]' '[:lower:]' <<< "${2:?missing --device-order value}")"; shift 2 ;;
      --health-policy) health_policy="${2:?missing --health-policy value}"; shift 2 ;;
      --health-evidence) health_evidence="${2:?missing --health-evidence value}"; shift 2 ;;
      --health-evidence-root) health_evidence_root="${2:?missing --health-evidence-root value}"; shift 2 ;;
      --evidence-server) evidence_server="${2:?missing --evidence-server value}"; shift 2 ;;
      --max-health-evidence-age-days) max_health_evidence_age_days="${2:?missing evidence age value}"; shift 2 ;;
      --all-matches|--auto-select) all_matches=1; shift ;;
      --non-interactive) non_interactive=1; shift ;;
      --review-format) review_format="${2:?missing --review-format value}"; shift 2 ;;
      --dataset) dataset="${2:?missing --dataset value}"; shift 2 ;;
      --mountpoint) mountpoint="${2:?missing --mountpoint value}"; shift 2 ;;
      --allow-signature-wipe) allow_signature_wipe=1; shift ;;
      --config) output="${2:?missing --config value}"; shift 2 ;;
      --replace) replace=1; shift ;;
      --inventory-file) inventory_file="${2:?missing --inventory-file value}"; shift 2 ;;
      --install-deps) shift ;;
      -h|--help|help) zfs.config.usage; return 0 ;;
      *) zfs.die "Unknown configuration option: $1" ;;
    esac
  done

  [[ "${tolerance}" =~ ^[0-9]+([.][0-9]+)?$ ]] || zfs.die "Size tolerance must be numeric"
  awk -v value="${tolerance}" 'BEGIN { exit !(value > 0 && value <= 5) }' || zfs.die "Size tolerance must be greater than 0 and no more than 5 percent"
  zfs.health.policy.validate "${health_policy}"
  [[ "${max_health_evidence_age_days}" =~ ^[0-9]+$ && "${max_health_evidence_age_days}" -gt 0 ]] || zfs.die "Health evidence age must be a positive whole number of days"
  [[ -z "${health_evidence_root}" || -n "${health_evidence}" ]] || zfs.die "--health-evidence-root requires --health-evidence"
  [[ -z "${evidence_server}" || -n "${health_evidence}" ]] || zfs.die "--evidence-server requires --health-evidence"
  [[ "${health_policy}" != "bht-required" || -n "${health_evidence}" ]] || zfs.die "bht-required requires --health-evidence"
  ((${#device_identifiers[@]} == 0 || ${#serial_identifiers[@]} == 0)) || zfs.die "Use either --device or --serial, not both"
  case "${transport}" in sas|sata|scsi|nvme|usb|any) ;; *) zfs.die "Unsupported transport filter: ${transport}" ;; esac
  case "${media}" in hdd|ssd|any) ;; *) zfs.die "Unsupported media filter: ${media}" ;; esac
  case "${review_format}" in pretty-json|table) ;; *) zfs.die "Review format must be pretty-json or table" ;; esac
  case "${device_order}" in auto|slot|selection|stable-path) ;; *) zfs.die "Device order must be auto, slot, selection, or stable-path" ;; esac
  dataset="${dataset:-${pool}/${ZFS_DEFAULT_DATASET_LEAF}}"
  mountpoint="${mountpoint:-/media/${dataset}}"
  [[ "${dataset}" == "${pool}/"* ]] || zfs.die "Dataset must be a child of pool ${pool}"
  [[ "${mountpoint}" == /* && "${mountpoint}" != "/" ]] || zfs.die "Mountpoint must be an absolute non-root path"
  [[ "${pool}" =~ ^[A-Za-z][A-Za-z0-9_.:-]*$ ]] || zfs.die "Invalid ZFS pool name: ${pool}"
  zfs.config.safe.output "${output}"

  if [[ -e "${output}" ]]; then
    ((replace == 1)) || zfs.die "${output} already exists; use --replace to create a backup"
    cp -p "${output}" "${output}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  fi

  if [[ -n "${inventory_file}" ]]; then
    tmp="$(mktemp)"
    zfs.inventory.apply.health "${inventory_file}" "${tmp}" "${health_policy}" "${health_evidence}" "${health_evidence_root}" "${evidence_server}" "${max_health_evidence_age_days}"
    inventory="$(cat "${tmp}")"
    rm -f "${tmp}"
  else
    tmp="$(mktemp)"
    zfs.inventory.collect "${health_policy}" "${health_evidence}" "${health_evidence_root}" "${evidence_server}" "${max_health_evidence_age_days}" > "${tmp}"
    inventory="$(cat "${tmp}")"
    rm -f "${tmp}"
  fi
  if [[ -n "${requested_size}" ]]; then
    requested_bytes="$(zfs.size.to.bytes "${requested_size}")"
    lower_requested="$(awk -v value="${requested_bytes}" -v tolerance="${tolerance}" 'BEGIN { printf "%.0f", value * (1 - tolerance/100) }')"
    upper_requested="$(awk -v value="${requested_bytes}" -v tolerance="${tolerance}" 'BEGIN { printf "%.0f", value * (1 + tolerance/100) }')"
    filter_size_json="$(jq -n -c --argjson minimum "${lower_requested}" --argjson maximum "${upper_requested}" '{minimum_bytes:$minimum,maximum_bytes:$maximum}')"
  fi

  if [[ -n "${avoid_identifiers[*]-}" ]]; then
    for identifier in "${avoid_identifiers[@]}"; do
      avoid_json="$(jq -c --arg identifier "${identifier}" '. + [$identifier]' <<< "${avoid_json}")"
    done
  fi
  if [[ -n "${model_filters[*]-}" ]]; then
    for identifier in "${model_filters[@]}"; do
      model_json="$(jq -c --arg model "${identifier}" '. + [$model]' <<< "${model_json}")"
    done
  fi
  if [[ -n "${serial_identifiers[*]-}" ]]; then
    for identifier in "${serial_identifiers[@]}"; do
      serial_json="$(jq -c --arg serial "${identifier}" '. + [$serial]' <<< "${serial_json}")"
    done
  fi
  [[ "$(jq 'length' <<< "${serial_json}")" -eq "$(jq 'unique|length' <<< "${serial_json}")" ]] || zfs.die "Duplicate --serial values are not allowed"

  candidates="$(jq -c \
    --arg transport "${transport}" --arg media "${media}" \
    --argjson minimum "${lower_requested}" --argjson maximum "${upper_requested}" --argjson use_size "$( [[ -n "${requested_size}" ]] && printf true || printf false )" \
    --argjson avoided "${avoid_json}" --argjson models "${model_json}" '
      def norm_model: ascii_downcase | gsub("[[:space:]]+"; " ") | gsub("^[[:space:]]+|[[:space:]]+$"; "");
      [.disks[] |
        . as $disk |
        select(.eligible == true) |
        select($transport == "any" or ((.transport // "")|ascii_downcase) == $transport) |
        select($media == "any" or (.media // (if .rotational then "hdd" else "ssd" end)) == $media) |
        select(($use_size|not) or (.size_bytes >= $minimum and .size_bytes <= $maximum)) |
        select(($models|length)==0 or ([ $models[] | norm_model ] | index(($disk.model|norm_model))) != null) |
        select(([$avoided[] as $a | (.path == $a or .stable_path == $a or .wwn == $a or .serial == $a or .kernel == $a)] | any) | not)
      ] | sort_by(if .observed_slot_index==null then 1 else 0 end,.observed_slot_scope,.observed_slot_index,.stable_path)' <<< "${inventory}")"

  zfs.config.review.print "${inventory}" "${candidates}" "${transport}" "${media}" \
    "${filter_size_json}" "${model_json}" "${avoid_json}" "${review_format}"

  if [[ -n "${device_identifiers[*]-}" ]]; then
    device_count="${#device_identifiers[@]}"
  fi
  if [[ -n "${serial_identifiers[*]-}" ]]; then
    serial_count="${#serial_identifiers[@]}"
  fi
  if ((device_count > 0 || serial_count > 0)); then
    explicit_selection=1
    selected='[]'
    if ((serial_count > 0)); then
      device_identifiers=("${serial_identifiers[@]}")
    fi
    for identifier in "${device_identifiers[@]}"; do
      if ((serial_count > 0)); then
        matches="$(jq -c --arg serial "${identifier}" '[.disks[] | select(.serial==$serial)]' <<< "${inventory}")"
      else
        matches="$(zfs.identifier.filter <(printf '%s\n' "${inventory}") "${identifier}")"
      fi
      match_count="$(jq 'length' <<< "${matches}")"
      [[ "${match_count}" -eq 1 ]] || zfs.die "Explicit identifier must match exactly one disk: ${identifier}"
      match="$(jq -c '.[0]' <<< "${matches}")"
      if ! jq -e --arg stable "$(jq -r '.stable_path' <<< "${match}")" 'map(.stable_path) | index($stable) != null' <<< "${candidates}" >/dev/null; then
        zfs.die "Explicit disk is not eligible under current filters: ${identifier}"
      fi
      selected="$(jq -c --argjson item "${match}" '. + [$item]' <<< "${selected}")"
    done
  else
    candidate_count="$(jq 'length' <<< "${candidates}")"
    [[ "${candidate_count}" -gt 0 ]] || zfs.die "No eligible disks match the supplied filters"
    if ((all_matches == 1)); then
      selected="${candidates}"
    else
      [[ "${non_interactive}" -eq 0 && -r /dev/tty && -w /dev/tty ]] || zfs.die "Non-interactive selection requires --device or --all-matches"
      interactive=1
      selected="$(zfs.config.choose.interactive "${candidates}")"
    fi
  fi

  selected_count="$(jq 'length' <<< "${selected}")"
  [[ "${selected_count}" -gt 0 ]] || zfs.die "No devices were selected"
  duplicate_count="$(jq '([.[].stable_path] | length) - ([.[].stable_path] | unique | length)' <<< "${selected}")"
  [[ "${duplicate_count}" -eq 0 ]] || zfs.die "Selected devices are not unique"
  signature_count="$(jq '[.[].signatures[]?] | length' <<< "${selected}")"
  if [[ "${signature_count}" -gt 0 && "${allow_signature_wipe}" -ne 1 ]]; then
    zfs.die "Selected devices contain signatures; rerun with explicit --allow-signature-wipe only after review"
  fi

  order_result="$(zfs.config.order.resolve "${selected}" "${device_order}" "${explicit_selection}")"
  selected="$(jq -c '.devices' <<< "${order_result}")"
  order_requested="$(jq -r '.requested' <<< "${order_result}")"
  order_effective="$(jq -r '.effective' <<< "${order_result}")"
  order_source="$(jq -r '.source' <<< "${order_result}")"
  order_requires_manual="$(jq -r '.requires_manual' <<< "${order_result}")"

  if ((non_interactive == 0)) && [[ -r /dev/tty && -w /dev/tty ]]; then
    interactive=1
    reorder_result="$(zfs.config.reorder.interactive "${selected}" "$( [[ "${order_requires_manual}" == true ]] && printf 1 || printf 0 )")"
    selected="$(jq -c '.devices' <<< "${reorder_result}")"
    if [[ "$(jq -r '.overridden' <<< "${reorder_result}")" == true ]]; then
      order_effective="selection"
      order_source="operator-csv"
      order_requires_manual=false
    fi
    vdev_type="${vdev_type:-$(zfs.prompt "Data vdev type: mirror, raidz1, raidz2, or raidz3" "raidz2")}"
    vdev_count="${vdev_count:-$(zfs.prompt "Number of equal-width data vdevs" "1")}"
    if [[ "${vdev_count}" =~ ^[1-9][0-9]*$ ]] && ((selected_count % vdev_count == 0)); then
      per_vdev="${per_vdev:-$(zfs.prompt "Devices per vdev" "$((selected_count / vdev_count))")}"
    else
      per_vdev="${per_vdev:-$(zfs.prompt "Devices per vdev" "")}"
    fi
  else
    [[ "${order_requires_manual}" != true ]] || zfs.die "Non-interactive generation requires --device-order slot|selection|stable-path or an ordered --serial/--device selection when automatic slot ordering is ambiguous"
    [[ -n "${vdev_type}" ]] || zfs.die "Non-interactive generation requires --vdev-type"
    [[ -n "${vdev_count}" || -n "${per_vdev}" ]] || zfs.die "Non-interactive generation requires --vdev-count or --drives-per-vdev"
    if [[ -z "${vdev_count}" ]]; then
      [[ "${per_vdev}" =~ ^[1-9][0-9]*$ && $((selected_count % per_vdev)) -eq 0 ]] || zfs.die "Selected device count is not divisible by --drives-per-vdev"
      vdev_count="$((selected_count / per_vdev))"
    elif [[ -z "${per_vdev}" ]]; then
      [[ "${vdev_count}" =~ ^[1-9][0-9]*$ && $((selected_count % vdev_count)) -eq 0 ]] || zfs.die "Selected device count is not divisible by --vdev-count"
      per_vdev="$((selected_count / vdev_count))"
    fi
  fi
  zfs.config.validate.topology.args "${pool}" "${vdev_type}" "${vdev_count}" "${per_vdev}" "${selected_count}"

  grouped_json="$(jq -c --arg type "${vdev_type}" --argjson count "${vdev_count}" --argjson width "${per_vdev}" '
    def device($index): .[$index] | {
      label:("D" + (($index+1)|tostring|if length==1 then "0"+. else . end)),
      path:.stable_path, expected_wwn:.wwn, expected_serial:.serial,
      expected_size_bytes:.size_bytes, expected_transport:.transport,
      logical_sector_bytes:.logical_sector_bytes, physical_sector_bytes:.physical_sector_bytes,
      observed_slot_index:(.observed_slot_index // null),
      observed_slot_source:(.observed_slot_source // ""),
      observed_slot_scope:(.observed_slot_scope // ""),
      observed_hctl:(.observed_hctl // ""),
      observed_fault_domain:(.fault_domain // "unknown"),
      expected_health:{policy:.health_policy,effective:.effective_health,evidence_source_digest:(.health_evidence.source_digest // null)}
    };
    [range(0;$count) as $v | {
      name:("data-"+($v|tostring)), type:$type,
      devices:[range(0;$width) as $d | device(($v*$width)+$d)]
    }]' <<< "${selected}")"

  health_json="$(jq -c '{policy:.health_policy,evidence:.health_evidence}' <<< "${inventory}")"
  observed_hbas_json="$(jq -c '[.[].hba // "unknown"]|unique' <<< "${selected}")"
  topology_advisories_json="$(jq -n -c --argjson hbas "${observed_hbas_json}" 'if ($hbas|length)==1 then ["single-hba"] else [] end')"
  config_json="$(jq -n -S \
    --arg pool "${pool}" --arg dataset "${dataset}" --arg mountpoint "${mountpoint}" \
    --arg transport "${transport}" --arg media "${media}" --argjson allow_wipe "${allow_signature_wipe}" \
    --argjson size_filter "${filter_size_json}" --argjson avoided "${avoid_json}" --argjson models "${model_json}" --argjson serials "${serial_json}" \
    --argjson tolerance "${tolerance}" --argjson vdevs "${grouped_json}" --argjson health "${health_json}" \
    --arg order_requested "${order_requested}" --arg order_effective "${order_effective}" --arg order_source "${order_source}" \
    --argjson observed_hbas "${observed_hbas_json}" --argjson topology_advisories "${topology_advisories_json}" '
    {
      schema_version:1,
      generated_by:"setup/storage/zpool.config.sh",
      pool:{
        name:$pool,allow_signature_wipe:($allow_wipe==1),
        properties:{ashift:12,autotrim:"off"},
        filesystem_properties:{compression:"lz4",atime:"off",xattr:"sa",acltype:"posix",dnodesize:"auto",mountpoint:"none",canmount:"off"}
      },
      selection:{
        filters:{transport:(if $transport=="any" then [] else [$transport] end),media:$media,size_bytes:$size_filter,avoided:$avoided,models:$models,serials:$serials},
        health:$health,
        ordering:{requested:$order_requested,effective:$order_effective,source:$order_source},
        expected_size_tolerance_percent:$tolerance
      },
      topology:{grouping:"contiguous",observed_hbas:$observed_hbas,advisories:$topology_advisories},
      vdevs:$vdevs,
      datasets:[{name:$dataset,mountpoint:$mountpoint,properties:{canmount:"on",recordsize:"1M",dedup:"off"}}]
    }')"

  zfs.warn "Logical vdev grouping is not physical fault-domain isolation. Review HBAs, expanders, backplanes, and power domains."
  if ((interactive == 1)); then
    printf '%s\n' "${config_json}" | jq . >&2
    response="$(zfs.prompt "Type WRITE to save this editable configuration" "")"
    [[ "${response}" == "WRITE" ]] || zfs.die "Configuration write was not confirmed"
  else
    printf '%s\n' "${config_json}" | jq -r '
      "Pool: \(.pool.name)",
      "Layout: \(.vdevs|length) x \(.vdevs[0].devices|length) \(.vdevs[0].type)",
      (.datasets[] | "Dataset: \(.name) -> \(.mountpoint)")' >&2
  fi

  tmp="$(mktemp)"; canonical="$(mktemp)"
  printf '%s\n' "${config_json}" > "${tmp}"
  jq -S . "${tmp}" > "${canonical}"
  zfs.config.validate.structure "${canonical}"
  zfs.write.atomic "${output}" 0600 "${canonical}"
  rm -f "${tmp}" "${canonical}"
  zfs.log "Wrote ${output}"
  zfs.config.print.topology "${output}" >&2
}

zfs.config.print.topology() {
  local config="$1"
  jq -r '
    "Pool: \(.pool.name)",
    "Layout: \(.vdevs|length) x \(.vdevs[0].devices|length) \(.vdevs[0].type)",
    "Health policy: \(.selection.health.policy)",
    (if .selection.ordering then "Device order: requested=\(.selection.ordering.requested) effective=\(.selection.ordering.effective) source=\(.selection.ordering.source)" else "Device order: legacy-unrecorded" end),
    "Observed HBAs: \(.topology.observed_hbas|join(","))",
    (if (.topology.advisories|length)>0 then "Topology advisories: \(.topology.advisories|join(","))" else empty end),
    (.vdevs[] | "\(.name) \(.type):", (.devices[] | "  \(.label)  slot=\(.observed_slot_index // "unknown") source=\(.observed_slot_source // "unknown") hctl=\(.observed_hctl // "unknown")  \(.path)  serial=\(.expected_serial) bytes=\(.expected_size_bytes) domain=\(.observed_fault_domain) health=\(.expected_health.effective)")),
    (.datasets[] | "Dataset: \(.name) -> \(.mountpoint)")' "${config}"
}

zfs_config_main() {
  local argument
  for argument in "$@"; do
    if [[ "${argument}" == "--install-deps" ]]; then zfs.install.dependencies; break; fi
  done
  zfs.require.base.commands
  zfs.config.build "$@"
}

zfs.config.validate.structure() {
  local config="$1" pool tolerance
  [[ -r "${config}" ]] || zfs.die "Configuration is unreadable: ${config}"
  jq -e . "${config}" >/dev/null || zfs.die "Configuration is not valid JSON: ${config}"
  jq -e '
    . as $root |
    def allowed_vdev: . == "mirror" or . == "raidz1" or . == "raidz2" or . == "raidz3";
    def minimum_width($type): if $type=="mirror" then 2 elif $type=="raidz1" then 3 elif $type=="raidz2" then 4 elif $type=="raidz3" then 5 else 999999 end;
    .schema_version == 1 and
    (.pool.name | type == "string" and test("^[A-Za-z][A-Za-z0-9_.:-]*$")) and
    (.pool.allow_signature_wipe | type == "boolean") and
    (.pool.properties|keys|sort) == ["ashift","autotrim"] and
    (.pool.properties.ashift | type=="number" and floor==. and .>=9 and .<=16) and
    (.pool.properties.autotrim == "on" or .pool.properties.autotrim == "off") and
    (.pool.filesystem_properties|keys|sort) == ["acltype","atime","canmount","compression","dnodesize","mountpoint","xattr"] and
    (.pool.filesystem_properties.compression | type=="string" and test("^(off|on|lz4|zstd(-[1-9][0-9]?)?|gzip(-[1-9])?)$")) and
    (.pool.filesystem_properties.atime == "on" or .pool.filesystem_properties.atime == "off") and
    (.pool.filesystem_properties.xattr == "sa" or .pool.filesystem_properties.xattr == "on" or .pool.filesystem_properties.xattr == "off") and
    (.pool.filesystem_properties.acltype == "posix" or .pool.filesystem_properties.acltype == "posixacl" or .pool.filesystem_properties.acltype == "nfsv4" or .pool.filesystem_properties.acltype == "off") and
    (.pool.filesystem_properties.dnodesize | type=="string" and test("^(auto|legacy|[0-9]+[kK])$")) and
    .pool.filesystem_properties.mountpoint == "none" and
    .pool.filesystem_properties.canmount == "off" and
    (.selection.filters.transport | type=="array" and all(.[]; .=="sas" or .=="sata" or .=="scsi" or .=="nvme" or .=="usb")) and
    (.selection.filters.media == "hdd" or .selection.filters.media == "ssd" or .selection.filters.media == "any") and
    (.selection.filters.avoided | type=="array" and all(.[]; type=="string")) and
    (.selection.filters.models | type=="array" and all(.[]; type=="string" and length>0)) and
    (.selection.filters.serials | type=="array" and all(.[]; type=="string" and length>0)) and
    (.selection.filters.size_bytes == null or (
      (.selection.filters.size_bytes.minimum_bytes | type=="number" and floor==. and .>0) and
      (.selection.filters.size_bytes.maximum_bytes | type=="number" and floor==. and .>0) and
      .selection.filters.size_bytes.minimum_bytes < .selection.filters.size_bytes.maximum_bytes
    )) and
    (.selection.expected_size_tolerance_percent | type == "number") and
    .selection.expected_size_tolerance_percent > 0 and
    .selection.expected_size_tolerance_percent <= 5 and
    (.selection.health.policy == "advisory" or .selection.health.policy == "smart-required" or .selection.health.policy == "bht-required") and
    (.selection.health.evidence.supplied | type=="boolean") and
    (.selection.health.evidence.file_sha256 == null or (.selection.health.evidence.file_sha256|type=="string" and test("^[0-9a-f]{64}$"))) and
    (.selection.health.evidence.server == null or (.selection.health.evidence.server|type=="string" and length>0)) and
    (.selection.health.evidence.max_age_days | type=="number" and floor==. and .>0) and
    (.selection.health.evidence.package_checks_requested | type=="boolean") and
    (.selection.ordering == null or (
      (.selection.ordering.requested | .=="auto" or .=="slot" or .=="selection" or .=="stable-path") and
      (.selection.ordering.effective | .=="slot" or .=="selection" or .=="stable-path") and
      (.selection.ordering.source | type=="string" and length>0)
    )) and
    (.topology.grouping == null or .topology.grouping == "contiguous") and
    (.topology.observed_hbas | type=="array" and length>0 and all(.[];type=="string" and length>0)) and
    (.topology.advisories | type=="array" and all(.[];.=="single-hba")) and
    (.vdevs | type == "array" and length > 0) and
    (all(.vdevs[]; . as $v |
      (.name | type=="string" and length>0) and
      (.type | allowed_vdev) and
      (.devices | type=="array" and length >= minimum_width($v.type))
    )) and
    ([.vdevs[].type]|unique|length)==1 and
    ([.vdevs[].devices|length]|unique|length)==1 and
    ([.vdevs[].name]|length)==([.vdevs[].name]|unique|length) and
    (all(.vdevs[].devices[];
      (.label | type == "string") and
      (.path | type == "string" and startswith("/dev/disk/by-id/") and (contains("-part")|not)) and
      (.expected_wwn | type == "string" and length > 0) and
      (.expected_serial | type == "string" and length > 0) and
      (.expected_size_bytes | type == "number" and floor==. and . > 0) and
      (.expected_transport | .=="sas" or .=="sata" or .=="scsi" or .=="nvme" or .=="usb") and
      (.logical_sector_bytes | type=="number" and floor==. and .>0) and
      (.physical_sector_bytes | type=="number" and floor==. and .>0) and
      (.observed_slot_index == null or (.observed_slot_index|type=="number" and floor==. and .>=0)) and
      (.observed_slot_source == null or (.observed_slot_source|type=="string")) and
      (.observed_slot_scope == null or (.observed_slot_scope|type=="string")) and
      (.observed_hctl == null or (.observed_hctl|type=="string")) and
      (.expected_health.policy == $root.selection.health.policy) and
      (.expected_health.effective | .=="passed" or .=="blocked" or .=="advisory") and
      (.expected_health.evidence_source_digest == null or (.expected_health.evidence_source_digest|type=="string" and test("^[0-9a-f]{64}$")))
    )) and
    ([.vdevs[].devices[].path] | length == (unique|length)) and
    ([.vdevs[].devices[].expected_wwn] | length == (unique|length)) and
    ([.vdevs[].devices[].expected_serial] | length == (unique|length)) and
    ([.vdevs[].devices[].label] | length == (unique|length)) and
    (if .selection.ordering.effective == "slot" then
      ([.vdevs[].devices[].observed_slot_index] | all(.[];type=="number")) and
      ([.vdevs[].devices[].observed_slot_index] | length == (unique|length)) and
      ([.vdevs[].devices[].observed_slot_index] == ([.vdevs[].devices[].observed_slot_index] | sort)) and
      ([.vdevs[].devices[].observed_slot_source] | unique | length)==1 and
      ([.vdevs[].devices[].observed_slot_scope] | unique | length)==1
    else true end) and
    (.datasets | type == "array") and
    (all(.datasets[];
      (.name | type=="string" and startswith($root.pool.name+"/") and test("^[A-Za-z0-9_.:-]+(/[A-Za-z0-9_.:-]+)+$")) and
      (.mountpoint | type=="string" and startswith("/") and .!="/") and
      (.properties|keys|sort)==["canmount","dedup","recordsize"] and
      (.properties.canmount=="on" or .properties.canmount=="off" or .properties.canmount=="noauto") and
      (.properties.recordsize | type=="string" and test("^(512|[1-9][0-9]*[KMG])$";"i")) and
      .properties.dedup=="off"
    )) and
    ([.datasets[].name]|length)==([.datasets[].name]|unique|length) and
    ([.datasets[].mountpoint]|length)==([.datasets[].mountpoint]|unique|length)
  ' "${config}" >/dev/null || zfs.die "Configuration violates the general ZFS feature schema"

  pool="$(jq -r '.pool.name' "${config}")"
  case "${pool}" in
    mirror|raidz|raidz1|raidz2|raidz3|spare|log|special|dedup)
      zfs.die "Reserved or unsafe pool name: ${pool}"
      ;;
  esac
  tolerance="$(jq -r '.selection.expected_size_tolerance_percent' "${config}")"
  [[ "${tolerance}" =~ ^[0-9]+([.][0-9]+)?$ ]] || zfs.die "Size tolerance must be numeric"
  if ! jq -e '.selection.ordering and .topology.grouping' "${config}" >/dev/null 2>&1; then
    zfs.warn "Configuration predates recorded device ordering; regenerate it before slot-sensitive acceptance"
  fi
}

zfs.pool.exists.or.importable() {
  local pool="$1" imported importable
  if zfs.is.true "${PROXMOX_ZFS_TEST_MODE:-0}"; then
    case ",${PROXMOX_ZFS_EXISTING_POOLS:-}," in *",${pool},"*) return 0 ;; esac
    case ",${PROXMOX_ZFS_IMPORTABLE_POOLS:-}," in *",${pool},"*) return 0 ;; esac
    return 1
  fi
  imported="$(zpool list -H -o name 2>/dev/null || true)"
  grep -Fxq -- "${pool}" <<< "${imported}" && return 0
  importable="$(zpool import 2>/dev/null || true)"
  awk -F: '/^[[:space:]]*pool:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' <<< "${importable}" | grep -Fxq -- "${pool}"
}

zfs.inventory.match.config() {
  local config="$1" inventory="$2" output="$3"
  jq -n -S --slurpfile config "${config}" --slurpfile inventory "${inventory}" '
    ($config[0]) as $c | ($inventory[0]) as $i |
    [$c.vdevs[].devices[] as $expected |
      ($i.disks | map(select(.stable_path == $expected.path))) as $matches |
      {
        expected:$expected,
        matches:($matches|length),
        actual:($matches[0] // null)
      }
    ]' > "${output}"
}

zfs.preflight.validate.devices() {
  local config="$1" inventory="$2" matched="$3" allow_wipe minimum maximum use_size tolerance failures expected_count policy
  allow_wipe="$(jq -r '.pool.allow_signature_wipe' "${config}")"
  use_size="$(jq -r '.selection.filters.size_bytes != null' "${config}")"
  minimum="$(jq -r '.selection.filters.size_bytes.minimum_bytes // 0' "${config}")"
  maximum="$(jq -r '.selection.filters.size_bytes.maximum_bytes // 0' "${config}")"
  tolerance="$(jq -r '.selection.expected_size_tolerance_percent' "${config}")"
  policy="$(jq -r '.selection.health.policy' "${config}")"

  failures="$(jq -r \
    --argjson minimum "${minimum}" --argjson maximum "${maximum}" --argjson tolerance "${tolerance}" \
    --argjson use_size "${use_size}" \
    --argjson allow_wipe "$( [[ "${allow_wipe}" == true ]] && printf 1 || printf 0 )" --arg policy "${policy}" '
    .[] |
    . as $m |
    if .matches != 1 then "\(.expected.label): expected path resolves to \(.matches) inventory entries"
    elif .actual.eligible != true then "\(.expected.label): ineligible: \(.actual.reasons|join(","))"
    elif .actual.whole_disk != true then "\(.expected.label): resolved path is not a whole disk"
    elif .actual.wwn != .expected.expected_wwn then "\(.expected.label): WWN mismatch"
    elif .actual.serial != .expected.expected_serial then "\(.expected.label): serial mismatch"
    elif ((.actual.transport // "")|ascii_downcase) != .expected.expected_transport then "\(.expected.label): transport mismatch"
    elif .actual.logical_sector_bytes != .expected.logical_sector_bytes then "\(.expected.label): logical sector size mismatch"
    elif .actual.physical_sector_bytes != .expected.physical_sector_bytes then "\(.expected.label): physical sector size mismatch"
    elif (.expected.observed_slot_index != null and .actual.observed_slot_index != .expected.observed_slot_index) then "\(.expected.label): observed slot index drift"
    elif ((.expected.observed_slot_source // "") != "" and .actual.observed_slot_source != .expected.observed_slot_source) then "\(.expected.label): observed slot source drift"
    elif ((.expected.observed_slot_scope // "") != "" and .actual.observed_slot_scope != .expected.observed_slot_scope) then "\(.expected.label): observed slot scope drift"
    elif ((.expected.observed_hctl // "") != "" and .actual.observed_hctl != .expected.observed_hctl) then "\(.expected.label): observed HCTL drift"
    elif .actual.health_policy != $policy then "\(.expected.label): health policy mismatch"
    elif ($policy=="smart-required" and .actual.smart_health!="passed") then "\(.expected.label): required SMART health did not pass"
    elif ($policy=="bht-required" and (.actual.health_evidence.accepted|not)) then "\(.expected.label): required BHT evidence was not accepted"
    elif ($policy=="bht-required" and .actual.health_evidence.source_digest != .expected.expected_health.evidence_source_digest) then "\(.expected.label): BHT evidence source digest changed"
    elif ($use_size and (.actual.size_bytes < $minimum or .actual.size_bytes > $maximum)) then "\(.expected.label): size outside configured byte range"
    elif (((.actual.size_bytes - .expected.expected_size_bytes) | if . < 0 then -. else . end) > (.expected.expected_size_bytes * $tolerance / 100)) then "\(.expected.label): actual byte size differs from expected_size_bytes beyond tolerance"
    elif (($allow_wipe == 0) and ((.actual.signatures|length) > 0)) then "\(.expected.label): signatures present while allow_signature_wipe=false"
    else empty end' "${matched}")"
  if [[ -n "${failures}" ]]; then
    printf '%s\n' "${failures}" >&2
    zfs.die "Device preflight failed"
  fi

  expected_count="$(jq '[.vdevs[].devices[]]|length' "${config}")"
  [[ "$(jq '[.[].actual.stable_path] | length' "${matched}")" -eq "${expected_count}" ]] || zfs.die "Not every configured device matched inventory"
  [[ "$(jq '[.[].actual.stable_path] | unique | length' "${matched}")" -eq "${expected_count}" ]] || zfs.die "Matched device paths are not unique"
  [[ "$(jq '[.[].actual.wwn] | unique | length' "${matched}")" -eq "${expected_count}" ]] || zfs.die "Matched WWNs are not unique"
  [[ "$(jq '[.[].actual.serial] | unique | length' "${matched}")" -eq "${expected_count}" ]] || zfs.die "Matched serials are not unique"
}

zfs.preflight.prepare() {
  local config="$1" inventory="$2" matched="$3" evidence="${4:-}" evidence_root="${5:-}" evidence_server="${6:-}" max_age_days="${7:-}" pool policy configured_evidence_hash observed_evidence_hash configured_server configured_max_age
  zfs.config.validate.structure "${config}"
  pool="$(jq -r '.pool.name' "${config}")"
  policy="$(jq -r '.selection.health.policy' "${config}")"
  configured_evidence_hash="$(jq -r '.selection.health.evidence.file_sha256 // ""' "${config}")"
  configured_server="$(jq -r '.selection.health.evidence.server // ""' "${config}")"
  configured_max_age="$(jq -r '.selection.health.evidence.max_age_days' "${config}")"
  if [[ -n "${evidence_server}" && "${evidence_server}" != "${configured_server}" ]]; then
    zfs.die "--evidence-server differs from the reviewed configuration"
  fi
  evidence_server="${configured_server}"
  if [[ -n "${max_age_days}" && "${max_age_days}" != "${configured_max_age}" ]]; then
    zfs.die "--max-health-evidence-age-days differs from the reviewed configuration"
  fi
  max_age_days="${configured_max_age}"
  if [[ "${policy}" == "bht-required" && -z "${evidence}" ]]; then
    zfs.die "bht-required preflight requires --health-evidence"
  fi
  if [[ -n "${configured_evidence_hash}" ]]; then
    [[ -n "${evidence}" ]] || zfs.die "Configuration was generated with health evidence; supply the same --health-evidence file"
    zfs.health.evidence.validate "${evidence}"
    observed_evidence_hash="$(zfs.health.evidence.hash "${evidence}")"
    [[ "${observed_evidence_hash}" == "${configured_evidence_hash}" ]] || zfs.die "Health evidence changed after configuration; generate a fresh configuration"
  fi
  zfs.require.command zpool
  zfs.require.command zfs
  zfs.require.command wipefs
  if zfs.pool.exists.or.importable "${pool}"; then
    zfs.die "Pool ${pool} already exists or is importable"
  fi
  zfs.inventory.collect "${policy}" "${evidence}" "${evidence_root}" "${evidence_server}" "${max_age_days}" > "${inventory}"
  zfs.inventory.match.config "${config}" "${inventory}" "${matched}"
  zfs.preflight.validate.devices "${config}" "${inventory}" "${matched}"
}

zfs.inventory.review.hash() {
  local config="$1" matched="$2" canonical
  canonical="$(mktemp)"
  jq -S --slurpfile config "${config}" '
    ($config[0].selection.health.policy) as $policy |
    map({
      expected:.expected,
      matches:.matches,
      actual:(.actual | {
        stable_path,wwn,serial,model,transport,size_bytes,logical_sector_bytes,physical_sector_bytes,
        whole_disk,signatures,reasons,eligible,hba,enclosure,slot,observed_hctl,
        observed_slot_index,observed_slot_source,observed_slot_scope,fault_domain
      } + (if $policy=="advisory" then {} else {
        smart_health,effective_health,health_policy,health_evidence
      } end))
    })
  ' "${matched}" > "${canonical}"
  zfs.sha256 "${canonical}"
  rm -f "${canonical}"
}

zfs.command.arrays() {
  local config="$1" matched="$2" output="$3"
  jq -n -S --slurpfile config "${config}" --slurpfile matched "${matched}" '
    ($config[0]) as $c | ($matched[0]) as $m |
    def options($flag;$object): reduce ($object|to_entries[]) as $p ([]; . + [$flag,($p.key+"="+($p.value|tostring))]);
    def pool_options: options("-o";$c.pool.properties) + options("-O";$c.pool.filesystem_properties);
    def topology: reduce $c.vdevs[] as $v ([]; . + [$v.type] + [$v.devices[].path]);
    def dataset_command($dataset):
      ["zfs","create"] + options("-o";({mountpoint:$dataset.mountpoint}+$dataset.properties)) + [$dataset.name];
    {
      zpool_dry_run:(["zpool","create","-n"] + pool_options + [$c.pool.name] + topology),
      zpool_create:(["zpool","create"] + pool_options + [$c.pool.name] + topology),
      signature_wipes:[$m[] | select((.actual.signatures|length)>0) | ["wipefs","--all","--force",.expected.path]],
      dataset_creates:[$c.datasets[] | dataset_command(.)]
    }' > "${output}"
}

zfs.capacity.estimate() {
  local config="$1" output="$2"
  jq -S '
    def parity($type): if $type=="raidz1" then 1 elif $type=="raidz2" then 2 elif $type=="raidz3" then 3 else 0 end;
    [.vdevs[] | . as $v |
      ([.devices[].expected_size_bytes]|min) as $smallest |
      {
        name:.name,type:.type,device_count:(.devices|length),smallest_member_bytes:$smallest,
        raw_bytes:([.devices[].expected_size_bytes]|add),
        estimated_usable_bytes:(if .type=="mirror" then $smallest else (((.devices|length)-parity(.type))*$smallest) end)
      }
    ] as $vdevs |
    {method:"smallest-member parity estimate; excludes ZFS metadata and slop space",vdevs:$vdevs,
     raw_bytes:([$vdevs[].raw_bytes]|add),estimated_usable_bytes:([$vdevs[].estimated_usable_bytes]|add)}
  ' "${config}" > "${output}"
}

zfs.json.command.print() {
  jq -r 'map(@sh)|join(" ")' <<< "$1"
}

zfs.json.command.run() {
  local command_json="$1" argument
  local -a command_argv=()
  while IFS= read -r argument; do command_argv+=("${argument}"); done < <(jq -r '.[]' <<< "${command_json}")
  "${command_argv[@]}"
}

zfs.plan.build() {
  local config="$1" plan_file="$2" evidence="${3:-}" evidence_root="${4:-}" evidence_server="${5:-}" max_age_days="${6:-}" work inventory matched commands capacity payload canonical plan_id
  local config_hash config_source inventory_hash requires_wipe dry_run_json
  work="$(mktemp -d)"
  inventory="${work}/inventory.json"; matched="${work}/matched.json"; commands="${work}/commands.json"; capacity="${work}/capacity.json"
  payload="${work}/payload.json"; canonical="${work}/canonical.json"
  zfs.preflight.prepare "${config}" "${inventory}" "${matched}" "${evidence}" "${evidence_root}" "${evidence_server}" "${max_age_days}"
  zfs.command.arrays "${config}" "${matched}" "${commands}"
  zfs.capacity.estimate "${config}" "${capacity}"
  requires_wipe="$(jq '[.signature_wipes[]] | length > 0' "${commands}")"

  zfs.config.print.topology "${config}"
  printf '\nIntended create command:\n  %s\n' "$(zfs.json.command.print "$(jq -c '.zpool_create' "${commands}")")"
  jq -c '.dataset_creates[]' "${commands}" | while IFS= read -r dry_run_json; do
    printf '  %s\n' "$(zfs.json.command.print "${dry_run_json}")"
  done
  printf '\nCapacity estimate (not guaranteed filesystem capacity):\n'
  jq -r '.vdevs[] | "  \(.name) \(.type): raw=\(.raw_bytes) estimated_usable=\(.estimated_usable_bytes) smallest_member=\(.smallest_member_bytes)"' "${capacity}"
  jq -r '"  pool: raw=\(.raw_bytes) estimated_usable=\(.estimated_usable_bytes)"' "${capacity}"
  zfs.warn "Logical grouping is not physical fault-domain isolation; confirm HBA, expander, backplane, and power placement."

  if [[ "${requires_wipe}" == true ]]; then
    [[ "$(jq -r '.pool.allow_signature_wipe' "${config}")" == true ]] || zfs.die "Signatures require allow_signature_wipe=true"
    zfs.warn "Signatures require a separate wipe-signatures action and a fresh plan before creation."
  else
    dry_run_json="$(jq -c '.zpool_dry_run' "${commands}")"
    zfs.json.command.run "${dry_run_json}"
  fi

  config_hash="$(zfs.sha256 "${config}")"
  config_source="$(cd "$(dirname "${config}")" && pwd -P)/$(basename "${config}")"
  inventory_hash="$(zfs.inventory.review.hash "${config}" "${matched}")"
  jq -n -S \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg config_hash "${config_hash}" --arg config_source "${config_source}" \
    --arg inventory_hash "${inventory_hash}" --argjson requires_wipe "${requires_wipe}" \
    --slurpfile configuration "${config}" --slurpfile inventory "${matched}" --slurpfile commands "${commands}" --slurpfile capacity "${capacity}" '
    {
      schema_version:1,generated_at:$generated_at,configuration_source:$config_source,config_hash:$config_hash,inventory_hash:$inventory_hash,
      plan_kind:(if $requires_wipe then "signature-wipe" else "create" end),
      requires_signature_wipe:$requires_wipe,
      configuration:$configuration[0],inventory:$inventory[0],capacity:$capacity[0],commands:$commands[0]
    }' > "${payload}"
  jq -S . "${payload}" > "${canonical}"
  plan_id="$(zfs.sha256 "${canonical}")"
  jq -S --arg plan_id "${plan_id}" '. + {plan_id:$plan_id}' "${canonical}" > "${payload}"
  zfs.write.atomic "${plan_file}" 0600 "${payload}"
  rm -rf "${work}"
  zfs.log "Wrote immutable plan ${plan_file}"
  printf 'plan_id=%s\n' "${plan_id}"
  printf 'plan_kind=%s\n' "$(jq -r '.plan_kind' "${plan_file}")"
}

zfs.plan.verify.id() {
  local plan_file="$1" supplied="$2" temporary expected observed
  [[ -r "${plan_file}" ]] || zfs.die "Plan is unreadable: ${plan_file}"
  jq -e '.schema_version == 1 and (.plan_id|type=="string")' "${plan_file}" >/dev/null || zfs.die "Invalid plan schema"
  expected="$(jq -r '.plan_id' "${plan_file}")"
  [[ "${supplied}" == "${expected}" ]] || zfs.die "Supplied plan ID does not match ${plan_file}"
  temporary="$(mktemp)"
  jq -S 'del(.plan_id)' "${plan_file}" > "${temporary}"
  observed="$(zfs.sha256 "${temporary}")"
  rm -f "${temporary}"
  [[ "${observed}" == "${expected}" ]] || zfs.die "Plan contents were modified after planning"
}

zfs.plan.revalidate() {
  local plan_file="$1" evidence="${2:-}" evidence_root="${3:-}" evidence_server="${4:-}" max_age_days="${5:-}" work config inventory matched expected_hash actual_hash pool config_source config_hash
  work="$(mktemp -d)"; config="${work}/config.json"; inventory="${work}/inventory.json"; matched="${work}/matched.json"
  jq -S '.configuration' "${plan_file}" > "${config}"
  zfs.config.validate.structure "${config}"
  config_source="$(jq -r '.configuration_source // empty' "${plan_file}")"
  config_hash="$(jq -r '.config_hash' "${plan_file}")"
  [[ -n "${config_source}" && -r "${config_source}" ]] || zfs.die "Original zpool.config is missing; generate a fresh plan"
  [[ "$(zfs.sha256 "${config_source}")" == "${config_hash}" ]] || zfs.die "zpool.config changed after planning; generate a fresh plan"
  pool="$(jq -r '.pool.name' "${config}")"
  if [[ "$(jq -r '.plan_kind' "${plan_file}")" == create ]] && zfs.pool.exists.or.importable "${pool}"; then
    zfs.die "Pool ${pool} already exists or is importable"
  fi
  zfs.preflight.prepare "${config}" "${inventory}" "${matched}" "${evidence}" "${evidence_root}" "${evidence_server}" "${max_age_days}"
  expected_hash="$(jq -r '.inventory_hash' "${plan_file}")"
  actual_hash="$(zfs.inventory.review.hash "${config}" "${matched}")"
  [[ "${actual_hash}" == "${expected_hash}" ]] || zfs.die "Device inventory changed after planning; generate a fresh plan"
  rm -rf "${work}"
}

zfs.require.regular.entrypoint() {
  local entrypoint="${PROXMOX_ZFS_ENTRYPOINT_FILE:-}"
  if zfs.is.true "${PROXMOX_ZFS_TEST_MODE:-0}"; then return; fi
  [[ -n "${entrypoint}" && -f "${entrypoint}" ]] || zfs.die "Destructive actions cannot run from a streamed shell; download and inspect setup/storage/zfs.sh first"
}

zfs.state.write() {
  local state_dir="$1" stage="$2" plan_id="$3" temporary
  mkdir -p "${state_dir}"; chmod 0700 "${state_dir}"
  temporary="$(mktemp)"
  jq -n -S --arg stage "${stage}" --arg plan_id "${plan_id}" --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{stage:$stage,plan_id:$plan_id,updated_at:$updated_at}' > "${temporary}"
  zfs.write.atomic "${state_dir}/state.json" 0600 "${temporary}"
  rm -f "${temporary}"
}

zfs.lock.acquire() {
  local pool="$1"
  if zfs.is.true "${PROXMOX_ZFS_TEST_MODE:-0}"; then return; fi
  zfs.require.command flock
  mkdir -p "${PROXMOX_ZFS_LOCK_ROOT:-/run/lock}"
  exec {ZFS_FEATURE_LOCK_FD}>"${PROXMOX_ZFS_LOCK_ROOT:-/run/lock}/proxmox-zfs-${pool}.lock"
  flock -n "${ZFS_FEATURE_LOCK_FD}" || zfs.die "Another ZFS feature operation holds the ${pool} lock"
}

zfs.signatures.wipe() {
  local plan_file="$1" plan_id="$2" confirm_pool="$3" confirmed_all="$4" evidence="${5:-}" evidence_root="${6:-}" evidence_server="${7:-}" max_age_days="${8:-}" pool state_dir command_json response path
  zfs.require.regular.entrypoint
  zfs.require.root
  zfs.plan.verify.id "${plan_file}" "${plan_id}"
  [[ "$(jq -r '.plan_kind' "${plan_file}")" == "signature-wipe" ]] || zfs.die "Plan does not require signature wiping"
  pool="$(jq -r '.configuration.pool.name' "${plan_file}")"
  [[ "${confirm_pool}" == "${pool}" ]] || zfs.die "--confirm-wipe must exactly match pool name ${pool}"
  zfs.lock.acquire "${pool}"
  zfs.plan.revalidate "${plan_file}" "${evidence}" "${evidence_root}" "${evidence_server}" "${max_age_days}"
  if ((confirmed_all != 1)); then
    [[ -r /dev/tty && -w /dev/tty ]] || zfs.die "Non-interactive signature wiping requires --yes"
    while IFS= read -r path; do
      response="$(zfs.prompt "Type WIPE ${path} to confirm this device" "")"
      [[ "${response}" == "WIPE ${path}" ]] || zfs.die "Signature wipe was not confirmed for ${path}"
    done < <(jq -r '.commands.signature_wipes[][3]' "${plan_file}")
  fi
  state_dir="${ZFS_DEFAULT_STATE_ROOT}/${pool}"
  zfs.state.write "${state_dir}" "signature-wipe-started" "${plan_id}"
  while IFS= read -r command_json; do
    zfs.log "Executing reviewed signature wipe: $(zfs.json.command.print "${command_json}")"
    zfs.json.command.run "${command_json}"
  done < <(jq -c '.commands.signature_wipes[]' "${plan_file}")
  if command -v udevadm >/dev/null 2>&1; then udevadm settle; fi
  zfs.state.write "${state_dir}" "signatures-wiped-replan-required" "${plan_id}"
  zfs.log "Signature wiping complete. Generate and review a fresh create plan; this plan cannot create the pool."
}

zfs.pool.apply() {
  local plan_file="$1" plan_id="$2" confirm_pool="$3" mode="$4" confirmed="$5" evidence="${6:-}" evidence_root="${7:-}" evidence_server="${8:-}" max_age_days="${9:-}" pool state_dir command_json response accepted_config_source accepted_config
  zfs.require.regular.entrypoint
  zfs.require.root
  [[ "${mode}" == "create" ]] || zfs.die "Creation requires the explicit option --mode create"
  zfs.plan.verify.id "${plan_file}" "${plan_id}"
  [[ "$(jq -r '.plan_kind' "${plan_file}")" == "create" ]] || zfs.die "Signature-wipe plans cannot create a pool; wipe, re-inventory, and re-plan"
  [[ "$(jq -r '.requires_signature_wipe' "${plan_file}")" == false ]] || zfs.die "Creation plan still requires signature wiping"
  pool="$(jq -r '.configuration.pool.name' "${plan_file}")"
  [[ "${confirm_pool}" == "${pool}" ]] || zfs.die "--confirm-create must exactly match pool name ${pool}"
  zfs.lock.acquire "${pool}"
  zfs.plan.revalidate "${plan_file}" "${evidence}" "${evidence_root}" "${evidence_server}" "${max_age_days}"
  if ((confirmed != 1)); then
    [[ -r /dev/tty && -w /dev/tty ]] || zfs.die "Non-interactive creation requires --yes"
    response="$(zfs.prompt "Type yes to create pool ${pool} from plan ${plan_id}" "no")"
    [[ "${response}" == "yes" ]] || zfs.die "Pool creation was not confirmed"
  fi
  state_dir="${ZFS_DEFAULT_STATE_ROOT}/${pool}"
  mkdir -p "${state_dir}"; chmod 0700 "${state_dir}"
  cp "${plan_file}" "${state_dir}/accepted-plan.json"; chmod 0600 "${state_dir}/accepted-plan.json"
  accepted_config_source="$(mktemp)"
  accepted_config="${state_dir}/accepted-config.json"
  jq -S '.configuration' "${plan_file}" > "${accepted_config_source}"
  zfs.write.atomic "${accepted_config}" 0600 "${accepted_config_source}"
  rm -f "${accepted_config_source}"
  zfs.state.write "${state_dir}" "pool-create-started" "${plan_id}"
  command_json="$(jq -c '.commands.zpool_create' "${plan_file}")"
  if jq -e 'index("-f") != null' <<< "${command_json}" >/dev/null; then
    zfs.die "Refusing create command containing -f"
  fi
  zfs.log "Executing reviewed create command: $(zfs.json.command.print "${command_json}")"
  zfs.json.command.run "${command_json}"
  zfs.state.write "${state_dir}" "pool-created" "${plan_id}"
  while IFS= read -r command_json; do
    zfs.log "Creating declared dataset: $(zfs.json.command.print "${command_json}")"
    zfs.json.command.run "${command_json}"
  done < <(jq -c '.commands.dataset_creates[]' "${plan_file}")
  zfs.state.write "${state_dir}" "datasets-created" "${plan_id}"
  zfs.verify.config "${accepted_config}"
  zfs.state.write "${state_dir}" "verified" "${plan_id}"
  zfs.log "Pool ${pool} created and verified"
}

zfs.verify.topology() {
  local config="$1" pool status_file expected_file observed_file block_file vdev_index path basename missing=0
  pool="$(jq -r '.pool.name' "${config}")"
  status_file="$(mktemp)"
  expected_file="$(mktemp)"
  observed_file="$(mktemp)"
  zpool status -P "${pool}" > "${status_file}"
  jq -r '.vdevs[] | "\(.type):\(.devices|length)"' "${config}" > "${expected_file}"
  awk '
    function emit() { if (active) print type ":" count }
    $1 ~ /^(mirror|raidz1|raidz2|raidz3)-[0-9]+$/ {
      emit(); type=$1; sub(/-[0-9]+$/, "", type); count=0; active=1; next
    }
    active && $1 ~ /^\/dev\// { count++ }
    END { emit() }
  ' "${status_file}" > "${observed_file}"
  if ! diff -u "${expected_file}" "${observed_file}" >/dev/null; then
    cat "${status_file}" >&2
    diff -u "${expected_file}" "${observed_file}" >&2 || true
    rm -f "${status_file}" "${expected_file}" "${observed_file}"
    zfs.die "Post-create vdev type or width mismatch"
  fi
  while IFS=$'\t' read -r vdev_index path; do
    block_file="$(mktemp)"
    awk -v target="$((vdev_index + 1))" '
      $1 ~ /^(mirror|raidz1|raidz2|raidz3)-[0-9]+$/ { group++; active=(group==target); next }
      active { print }
    ' "${status_file}" > "${block_file}"
    basename="$(basename "${path}")"
    if ! grep -Eq -- "${basename}(-part1)?([[:space:]]|$)" "${block_file}"; then
      zfs.warn "Post-create vdev $((vdev_index + 1)) is missing ${path}"
      missing=1
    fi
    rm -f "${block_file}"
  done < <(jq -r '.vdevs|to_entries[] as $v|$v.value.devices[]|[$v.key,.path]|@tsv' "${config}")
  rm -f "${status_file}" "${expected_file}" "${observed_file}"
  ((missing == 0)) || zfs.die "Post-create device membership mismatch"
}

zfs.expect.zpool.property() {
  local pool="$1" property="$2" expected="$3" observed
  observed="$(zpool get -H -o value "${property}" "${pool}" 2>/dev/null | head -n1)"
  [[ "${observed}" == "${expected}" ]] || zfs.die "Pool property ${property}: expected ${expected}, observed ${observed:-missing}"
}

zfs.property.value.canonical() {
  local property="$1" value="$2"
  case "${property}:${value}" in
    acltype:posix|acltype:posixacl) printf 'posix\n' ;;
    *) printf '%s\n' "${value}" ;;
  esac
}

zfs.expect.zfs.property() {
  local dataset="$1" property="$2" expected="$3" observed expected_canonical observed_canonical
  observed="$(zfs get -H -o value "${property}" "${dataset}" 2>/dev/null | head -n1)"
  expected_canonical="$(zfs.property.value.canonical "${property}" "${expected}")"
  observed_canonical="$(zfs.property.value.canonical "${property}" "${observed}")"
  [[ "${observed_canonical}" == "${expected_canonical}" ]] || zfs.die "Dataset property ${dataset}:${property}: expected ${expected}, observed ${observed:-missing}"
}

zfs.verify.config() {
  local config="$1" pool dataset mountpoint property expected canmount mounted
  zfs.config.validate.structure "${config}"
  pool="$(jq -r '.pool.name' "${config}")"
  zpool list -H "${pool}" >/dev/null 2>&1 || zfs.die "Pool ${pool} is not imported"
  zfs.verify.topology "${config}"
  while IFS=$'\t' read -r property expected; do
    zfs.expect.zpool.property "${pool}" "${property}" "${expected}"
  done < <(jq -r '.pool.properties|to_entries[]|[.key,(.value|tostring)]|@tsv' "${config}")
  while IFS=$'\t' read -r property expected; do
    zfs.expect.zfs.property "${pool}" "${property}" "${expected}"
  done < <(jq -r '.pool.filesystem_properties|to_entries[]|[.key,(.value|tostring)]|@tsv' "${config}")
  while IFS=$'\t' read -r dataset mountpoint canmount; do
    zfs list -H -o name "${dataset}" >/dev/null 2>&1 || zfs.die "Dataset is missing: ${dataset}"
    zfs.expect.zfs.property "${dataset}" mountpoint "${mountpoint}"
    while IFS=$'\t' read -r property expected; do
      zfs.expect.zfs.property "${dataset}" "${property}" "${expected}"
    done < <(jq -r --arg dataset "${dataset}" '.datasets[]|select(.name==$dataset)|.properties|to_entries[]|[.key,(.value|tostring)]|@tsv' "${config}")
    mounted="$(zfs get -H -o value mounted "${dataset}" 2>/dev/null | head -n1)"
    if [[ "${canmount}" == "on" ]]; then
      [[ "${mounted}" == "yes" ]] || zfs.die "Dataset ${dataset} is not mounted"
      [[ -d "${mountpoint}" ]] || zfs.die "Dataset mountpoint is unavailable: ${mountpoint}"
    else
      [[ "${mounted}" == "no" ]] || zfs.die "Dataset ${dataset} unexpectedly mounted while canmount=${canmount}"
    fi
  done < <(jq -r '.datasets[]|[.name,.mountpoint,.properties.canmount]|@tsv' "${config}")
  zfs.log "Verified ${pool}: configured topology, device membership, properties, datasets, and mount state"
}

zfs.pool.usage() {
  cat <<'EOF'
Usage:
  setup/storage/zfs.sh configure [configuration flags]
  setup/storage/zfs.sh inventory [--output text|json] [--output-file FILE] [health options]
  setup/storage/zfs.sh validate-config [--config FILE]
  setup/storage/zfs.sh preflight [--config FILE] [evidence options]
  setup/storage/zfs.sh plan [--config FILE] [--plan-file FILE] [evidence options]
  setup/storage/zfs.sh wipe-signatures --plan-file FILE --plan-id SHA256 --mode wipe-signatures --confirm-wipe POOL [--yes]
  setup/storage/zfs.sh apply --plan-file FILE --plan-id SHA256 --mode create --confirm-create POOL [--yes]
  setup/storage/zfs.sh status --pool POOL [--output text|json]
  setup/storage/zfs.sh verify [--config FILE]
  setup/storage/zfs.sh --help

Configuration supports equal-width mirror, RAIDZ1, RAIDZ2, and RAIDZ3 data
vdevs with operator-selected whole disks. Signature wiping is a distinct
reviewed action. Creation never adds zpool -f. Plan and destructive actions are
refused from a streamed shell. Health is advisory unless an operator explicitly
selects smart-required or bht-required.
EOF
}

zfs.action.inventory() {
  local output="text" output_file="" inventory install_deps=0 health_policy="${ZFS_DEFAULT_HEALTH_POLICY}" health_evidence="" health_evidence_root="" evidence_server="" max_age_days="${ZFS_DEFAULT_HEALTH_EVIDENCE_AGE_DAYS}"
  while (($#)); do
    case "$1" in
      --output) output="${2:?missing --output value}"; shift 2 ;;
      --output-file) output_file="${2:?missing --output-file value}"; shift 2 ;;
      --install-deps) install_deps=1; shift ;;
      --health-policy) health_policy="${2:?missing --health-policy value}"; shift 2 ;;
      --health-evidence) health_evidence="${2:?missing --health-evidence value}"; shift 2 ;;
      --health-evidence-root) health_evidence_root="${2:?missing --health-evidence-root value}"; shift 2 ;;
      --evidence-server) evidence_server="${2:?missing --evidence-server value}"; shift 2 ;;
      --max-health-evidence-age-days) max_age_days="${2:?missing evidence age value}"; shift 2 ;;
      *) zfs.die "Unknown inventory option: $1" ;;
    esac
  done
  ((install_deps == 0)) || zfs.install.dependencies
  [[ "${output}" == text || "${output}" == json ]] || zfs.die "Inventory output must be text or json"
  inventory="$(mktemp)"; zfs.inventory.collect "${health_policy}" "${health_evidence}" "${health_evidence_root}" "${evidence_server}" "${max_age_days}" > "${inventory}"
  if [[ -n "${output_file}" ]]; then
    zfs.write.atomic "${output_file}" 0600 "${inventory}"
  fi
  if [[ "${output}" == json ]]; then jq -S . "${inventory}"; else zfs.inventory.print.table "${inventory}"; fi
  rm -f "${inventory}"
}

zfs.action.validate.config() {
  local config="$(pwd -P)/zpool.config"
  while (($#)); do
    case "$1" in
      --config) config="${2:?missing --config value}"; shift 2 ;;
      *) zfs.die "Unknown validate-config option: $1" ;;
    esac
  done
  zfs.require.regular.entrypoint
  zfs.config.validate.structure "${config}"
  zfs.config.print.topology "${config}"
  zfs.log "Configuration schema and topology are valid; live hardware was not inspected"
}

zfs.action.preflight() {
  local config="$(pwd -P)/zpool.config" work inventory matched health_evidence="" health_evidence_root="" evidence_server="" max_age_days=""
  while (($#)); do
    case "$1" in
      --config) config="${2:?missing --config value}"; shift 2 ;;
      --health-evidence) health_evidence="${2:?missing --health-evidence value}"; shift 2 ;;
      --health-evidence-root) health_evidence_root="${2:?missing --health-evidence-root value}"; shift 2 ;;
      --evidence-server) evidence_server="${2:?missing --evidence-server value}"; shift 2 ;;
      --max-health-evidence-age-days) max_age_days="${2:?missing evidence age value}"; shift 2 ;;
      *) zfs.die "Unknown preflight option: $1" ;;
    esac
  done
  zfs.require.regular.entrypoint
  work="$(mktemp -d)"; inventory="${work}/inventory.json"; matched="${work}/matched.json"
  zfs.preflight.prepare "${config}" "${inventory}" "${matched}" "${health_evidence}" "${health_evidence_root}" "${evidence_server}" "${max_age_days}"
  zfs.config.print.topology "${config}"
  jq -r '.[] | "\(.expected.label) ok  \(.expected.path)  serial=\(.actual.serial) bytes=\(.actual.size_bytes) transport=\(.actual.transport) health=\(.actual.effective_health) bht=\(.actual.health_evidence.status) signatures=\(.actual.signatures|join(","))"' "${matched}"
  rm -rf "${work}"
  zfs.log "Preflight passed"
}

zfs.action.plan() {
  local config="$(pwd -P)/zpool.config" plan_file="$(pwd -P)/zpool.plan" health_evidence="" health_evidence_root="" evidence_server="" max_age_days=""
  while (($#)); do
    case "$1" in
      --config) config="${2:?missing --config value}"; shift 2 ;;
      --plan-file) plan_file="${2:?missing --plan-file value}"; shift 2 ;;
      --health-evidence) health_evidence="${2:?missing --health-evidence value}"; shift 2 ;;
      --health-evidence-root) health_evidence_root="${2:?missing --health-evidence-root value}"; shift 2 ;;
      --evidence-server) evidence_server="${2:?missing --evidence-server value}"; shift 2 ;;
      --max-health-evidence-age-days) max_age_days="${2:?missing evidence age value}"; shift 2 ;;
      *) zfs.die "Unknown plan option: $1" ;;
    esac
  done
  zfs.require.regular.entrypoint
  [[ ! -L "${plan_file}" ]] || zfs.die "Refusing symlink plan output: ${plan_file}"
  zfs.plan.build "${config}" "${plan_file}" "${health_evidence}" "${health_evidence_root}" "${evidence_server}" "${max_age_days}"
}

zfs.action.wipe() {
  local plan_file="" plan_id="" mode="" confirm="" yes=0 health_evidence="" health_evidence_root="" evidence_server="" max_age_days=""
  while (($#)); do
    case "$1" in
      --plan-file) plan_file="${2:?missing --plan-file value}"; shift 2 ;;
      --plan-id) plan_id="${2:?missing --plan-id value}"; shift 2 ;;
      --mode) mode="${2:?missing --mode value}"; shift 2 ;;
      --confirm-wipe) confirm="${2:?missing --confirm-wipe value}"; shift 2 ;;
      --health-evidence) health_evidence="${2:?missing --health-evidence value}"; shift 2 ;;
      --health-evidence-root) health_evidence_root="${2:?missing --health-evidence-root value}"; shift 2 ;;
      --evidence-server) evidence_server="${2:?missing --evidence-server value}"; shift 2 ;;
      --max-health-evidence-age-days) max_age_days="${2:?missing evidence age value}"; shift 2 ;;
      --yes) yes=1; shift ;;
      *) zfs.die "Unknown wipe-signatures option: $1" ;;
    esac
  done
  [[ -n "${plan_file}" && -n "${plan_id}" && -n "${confirm}" && "${mode}" == wipe-signatures ]] || \
    zfs.die "wipe-signatures requires --plan-file, --plan-id, --mode wipe-signatures, and --confirm-wipe; use --yes only for explicit all-device confirmation"
  zfs.signatures.wipe "${plan_file}" "${plan_id}" "${confirm}" "${yes}" "${health_evidence}" "${health_evidence_root}" "${evidence_server}" "${max_age_days}"
}

zfs.action.apply() {
  local plan_file="" plan_id="" mode="" confirm="" yes=0 health_evidence="" health_evidence_root="" evidence_server="" max_age_days=""
  while (($#)); do
    case "$1" in
      --plan-file) plan_file="${2:?missing --plan-file value}"; shift 2 ;;
      --plan-id) plan_id="${2:?missing --plan-id value}"; shift 2 ;;
      --mode) mode="${2:?missing --mode value}"; shift 2 ;;
      --confirm-create) confirm="${2:?missing --confirm-create value}"; shift 2 ;;
      --health-evidence) health_evidence="${2:?missing --health-evidence value}"; shift 2 ;;
      --health-evidence-root) health_evidence_root="${2:?missing --health-evidence-root value}"; shift 2 ;;
      --evidence-server) evidence_server="${2:?missing --evidence-server value}"; shift 2 ;;
      --max-health-evidence-age-days) max_age_days="${2:?missing evidence age value}"; shift 2 ;;
      --yes) yes=1; shift ;;
      *) zfs.die "Unknown apply option: $1" ;;
    esac
  done
  [[ -n "${plan_file}" && -n "${plan_id}" && -n "${confirm}" && "${mode}" == create ]] || \
    zfs.die "apply requires --plan-file, --plan-id, --mode create, and --confirm-create; non-interactive use also requires --yes"
  zfs.pool.apply "${plan_file}" "${plan_id}" "${confirm}" "${mode}" "${yes}" "${health_evidence}" "${health_evidence_root}" "${evidence_server}" "${max_age_days}"
}

zfs.action.status() {
  local pool="" output="text" status_json
  while (($#)); do
    case "$1" in
      --pool) pool="${2:?missing --pool value}"; shift 2 ;;
      --output) output="${2:?missing --output value}"; shift 2 ;;
      *) zfs.die "Unknown status option: $1" ;;
    esac
  done
  zfs.require.regular.entrypoint
  [[ -n "${pool}" ]] || zfs.die "status requires --pool"
  [[ "${output}" == text || "${output}" == json ]] || zfs.die "Status output must be text or json"
  if [[ "${output}" == text ]]; then
    zpool status -P "${pool}"
    zfs list -r -o name,used,available,recordsize,mountpoint,canmount,dedup "${pool}"
    return
  fi
  status_json="$(zpool status -j "${pool}" 2>/dev/null || true)"
  if [[ -n "${status_json}" ]] && jq -e . >/dev/null 2>&1 <<< "${status_json}"; then
    jq -S . <<< "${status_json}"
  else
    jq -n --arg pool "${pool}" --arg status "$(zpool status -P "${pool}")" --arg datasets "$(zfs list -H -r -o name,used,available,recordsize,mountpoint,canmount,dedup "${pool}")" \
      '{pool:$pool,status_text:$status,datasets_text:$datasets}'
  fi
}

zfs.action.verify() {
  local config="$(pwd -P)/zpool.config"
  while (($#)); do
    case "$1" in
      --config) config="${2:?missing --config value}"; shift 2 ;;
      *) zfs.die "Unknown verify option: $1" ;;
    esac
  done
  zfs.require.regular.entrypoint
  zfs.verify.config "${config}"
}

zfs_pool_main() {
  local action
  if [[ "$#" -eq 0 ]]; then
    action="--help"
  elif [[ "$1" == "--help" || "$1" == "-h" || "$1" == "help" ]]; then
    action="$1"
    shift
  elif [[ "$1" == -* ]]; then
    action="configure"
  else
    action="$1"
    shift
  fi
  case "${action}" in
    configure) zfs_config_main "$@" ;;
    inventory) zfs.action.inventory "$@" ;;
    validate-config) zfs.action.validate.config "$@" ;;
    preflight) zfs.action.preflight "$@" ;;
    plan) zfs.action.plan "$@" ;;
    wipe-signatures) zfs.action.wipe "$@" ;;
    apply) zfs.action.apply "$@" ;;
    status) zfs.action.status "$@" ;;
    verify) zfs.action.verify "$@" ;;
    -h|--help|help) zfs.pool.usage ;;
    *) zfs.pool.usage >&2; zfs.die "Unknown action: ${action}" ;;
  esac
}
