#!/usr/bin/env bash
# Shared implementation for setup/storage/zfs.sh and zpool.config.sh.
# This file is sourced by the public entrypoints.

ZFS_FEATURE_VERSION="0.0.6"
ZFS_DEFAULT_SIZE_TOLERANCE_PERCENT="1"
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

zfs.inventory.collect.live() {
  local lsblk_json row path kernel stable_path smart_json smart_text smart_health
  local transport smart_transport signatures_json reasons_json warnings_json
  local descendants mounts holders lvm_output md_output zpool_output ceph_output
  local tmp_rows entry type size rota media model vendor serial wwn ro rm log_sec phy_sec
  local hctl sysfs_path hba enclosure slot fault_domain command_name

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
    hba=""
    if [[ "${hctl}" =~ ^([0-9]+): ]]; then hba="host${BASH_REMATCH[1]}"; fi
    enclosure=""
    if [[ -n "${sysfs_path}" ]]; then enclosure="$(basename "$(dirname "${sysfs_path}")")"; fi
    slot="${hctl}"
    fault_domain="${hba:-unknown}:${enclosure:-unknown}:${slot:-unknown}"

    smart_json="$(smartctl -i -H -j "${path}" 2>/dev/null || true)"
    smart_text="$(smartctl -i "${path}" 2>/dev/null || true)"
    if [[ -z "${serial}" ]]; then serial="$(jq -r '.serial_number // ""' <<< "${smart_json:-{}}" 2>/dev/null || true)"; fi
    if [[ -z "${wwn}" && "${stable_path}" == /dev/disk/by-id/wwn-* ]]; then wwn="${stable_path##*/wwn-}"; fi
    smart_health="$(jq -r 'if .smart_status.passed == true then "passed" elif .smart_status.passed == false then "failed" else "unknown" end' <<< "${smart_json:-{}}" 2>/dev/null || printf unknown)"
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
    [[ "${smart_health}" == "passed" ]] || reasons_json="$(jq -c --arg reason "smart-${smart_health}" '. + [$reason]' <<< "${reasons_json}")"
    if [[ -n "${smart_transport}" && -n "${transport}" && "${transport}" != "${smart_transport}" ]]; then
      reasons_json="$(jq -c '. + ["transport-conflict"]' <<< "${reasons_json}")"
    fi
    if [[ "$(jq 'length' <<< "${signatures_json}")" -gt 0 ]]; then
      warnings_json="$(jq -c '. + ["signatures-present"]' <<< "${warnings_json}")"
    fi

    entry="$(jq -n -c \
      --arg kernel "${kernel}" --arg path "${path}" --arg stable_path "${stable_path}" \
      --arg wwn "${wwn}" --arg serial "${serial}" --arg model "${model}" --arg vendor "${vendor}" \
      --arg transport "${transport}" --arg media "${media}" --arg smart_health "${smart_health}" \
      --arg hba "${hba}" --arg enclosure "${enclosure}" --arg slot "${slot}" \
      --arg sysfs_path "${sysfs_path}" --arg fault_domain "${fault_domain}" \
      --argjson size_bytes "${size}" --argjson rotational "${rota}" \
      --argjson logical_sector_bytes "${log_sec}" --argjson physical_sector_bytes "${phy_sec}" \
      --argjson signatures "${signatures_json}" --argjson reasons "${reasons_json}" --argjson warnings "${warnings_json}" \
      '{kernel:$kernel,path:$path,stable_path:$stable_path,wwn:$wwn,serial:$serial,model:$model,vendor:$vendor,transport:$transport,media:$media,size_bytes:$size_bytes,rotational:$rotational,logical_sector_bytes:$logical_sector_bytes,physical_sector_bytes:$physical_sector_bytes,smart_health:$smart_health,hba:$hba,enclosure:$enclosure,slot:$slot,sysfs_path:$sysfs_path,fault_domain:$fault_domain,whole_disk:true,signatures:$signatures,reasons:$reasons,warnings:$warnings,eligible:($reasons|length==0)}')"
    printf '%s\n' "${entry}" >> "${tmp_rows}"
  done < <(jq -c '.blockdevices[]?' <<< "${lsblk_json}")

  jq -s '{schema_version:1,disks:sort_by(.stable_path,.kernel)}' "${tmp_rows}"
  rm -f "${tmp_rows}"
}

zfs.inventory.collect() {
  zfs.require.base.commands
  if [[ -n "${PROXMOX_ZFS_INVENTORY_FIXTURE:-}" ]]; then
    [[ -r "${PROXMOX_ZFS_INVENTORY_FIXTURE}" ]] || zfs.die "Inventory fixture is unreadable"
    jq -S . "${PROXMOX_ZFS_INVENTORY_FIXTURE}"
    return
  fi
  zfs.inventory.collect.live
}

zfs.inventory.print.table() {
  local inventory="$1"
  if command -v column >/dev/null 2>&1; then
    jq -r '
    def human: if .>=1099511627776 then (((./1099511627776)*100|round)/100|tostring)+"TiB" elif .>=1073741824 then (((./1073741824)*100|round)/100|tostring)+"GiB" else (tostring)+"B" end;
    ["INDEX","DEVICE","BY-ID","SERIAL","MODEL","TYPE","MEDIA","SIZE","SIZE_BYTES","SMART","DOMAIN","SIGNATURES","ELIGIBLE","REASON"],
    (.disks | to_entries[] | [
      (.key+1), .value.path, (.value.stable_path // "-"), (.value.serial // "-"),
      (.value.model // "-"), (.value.transport // "-"), (.value.media // (if .value.rotational then "hdd" else "ssd" end)), (.value.size_bytes|human), .value.size_bytes,
      (.value.smart_health // "unknown"), (.value.fault_domain // "unknown"), (.value.signatures|join(",")),
      .value.eligible, ((.value.reasons + .value.warnings)|join(","))
    ]) | @tsv' "${inventory}" | column -t -s $'\t'
  else
    jq -r '
      def human: if .>=1099511627776 then (((./1099511627776)*100|round)/100|tostring)+"TiB" elif .>=1073741824 then (((./1073741824)*100|round)/100|tostring)+"GiB" else (tostring)+"B" end;
      ["INDEX","DEVICE","BY-ID","SERIAL","MODEL","TYPE","MEDIA","SIZE","SIZE_BYTES","SMART","DOMAIN","SIGNATURES","ELIGIBLE","REASON"],
      (.disks | to_entries[] | [
        (.key+1), .value.path, (.value.stable_path // "-"), (.value.serial // "-"),
        (.value.model // "-"), (.value.transport // "-"), (.value.media // (if .value.rotational then "hdd" else "ssd" end)), (.value.size_bytes|human), .value.size_bytes,
        (.value.smart_health // "unknown"), (.value.fault_domain // "unknown"), (.value.signatures|join(",")),
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
  --pool NAME                         Pool name (default: archive)
  --vdev-type TYPE                   mirror, raidz1, raidz2, or raidz3
  --vdev-count NUMBER                Number of equal-width data vdevs
  --drives-per-vdev NUMBER           Devices in each data vdev
  --type TYPE                        sas, sata, scsi, nvme, usb, or any
  --media TYPE                       hdd, ssd, or any
  --size SIZE                        Exact-unit filter, e.g. 6TB or 5.5TiB
  --size-tolerance-percent NUMBER    Size range and identity tolerance (default: 1)
  --device IDENTIFIER                Select an exact disk (repeatable)
  --avoid IDENTIFIER                 Exclude exact path/by-id/WWN/serial (repeatable)
  --all-matches                      Select every eligible filtered candidate
  --non-interactive                  Require deterministic selection/topology flags
  --dataset POOL/DATASET             Dataset (default: <pool>/data)
  --mountpoint PATH                  Dataset mountpoint (default: /media/<pool>)
  --allow-signature-wipe             Permit a separate reviewed wipe plan
  --config PATH                      Output path (default: ./zpool.config)
  --replace                          Back up and replace an existing config
  --install-deps                     Explicitly install required Debian packages
  -h, --help                         Show this help

Interactive selection asks y/n/all/none for each eligible candidate. The size
filter is stored as explicit byte bounds; each disk's expected_size_bytes,
WWN, serial, transport, and sector sizes remain authoritative.
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

zfs.config.choose.interactive() {
  local candidates="$1" selected='[]' item answer include_rest=0 exclude_rest=0
  while IFS= read -r item; do
    if ((exclude_rest == 1)); then continue; fi
    if ((include_rest == 1)); then
      selected="$(jq -c --argjson item "${item}" '. + [$item]' <<< "${selected}")"
      continue
    fi
    while true; do
      answer="$(zfs.prompt "Include $(jq -r '.stable_path' <<< "${item}") serial=$(jq -r '.serial' <<< "${item}") bytes=$(jq -r '.size_bytes' <<< "${item}")? [y/n/all/none]" "n")"
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

zfs.config.reorder.interactive() {
  local selected="$1" response item index reordered='[]' duplicate_count
  printf '\nSelected device order:\n' >/dev/tty
  jq -r 'to_entries[] | "\(.key+1)) \(.value.stable_path) serial=\(.value.serial) domain=\(.value.fault_domain // \"unknown\")"' <<< "${selected}" >/dev/tty
  response="$(zfs.prompt "Ordered indexes as CSV (Enter keeps this order)" "")"
  [[ -n "${response}" ]] || { printf '%s\n' "${selected}"; return; }
  IFS=',' read -r -a selected_indexes <<< "${response}"
  [[ "${#selected_indexes[@]}" -eq "$(jq 'length' <<< "${selected}")" ]] || zfs.die "Reordering must include every selected index exactly once"
  for index in "${selected_indexes[@]}"; do
    index="${index//[[:space:]]/}"
    [[ "${index}" =~ ^[1-9][0-9]*$ ]] || zfs.die "Invalid reorder index: ${index}"
    item="$(jq -c --argjson index "$((index - 1))" '.[$index] // empty' <<< "${selected}")"
    [[ -n "${item}" ]] || zfs.die "Reorder index is out of range: ${index}"
    reordered="$(jq -c --argjson item "${item}" '. + [$item]' <<< "${reordered}")"
  done
  duplicate_count="$(jq '([.[].stable_path]|length)-([.[].stable_path]|unique|length)' <<< "${reordered}")"
  [[ "${duplicate_count}" -eq 0 ]] || zfs.die "Reordering contains duplicate indexes"
  printf '%s\n' "${reordered}"
}

zfs.config.build() {
  local pool="archive" vdev_type="" vdev_count="" per_vdev="" transport="any" media="any"
  local requested_size="" tolerance="${ZFS_DEFAULT_SIZE_TOLERANCE_PERCENT}"
  local dataset="" mountpoint="" all_matches=0 non_interactive=0 allow_signature_wipe=0
  local replace=0 inventory_file="" inventory candidates selected requested_bytes=0
  local lower_requested=0 upper_requested=0 candidate_count output="$(pwd -P)/zpool.config" tmp canonical
  local identifier matches match match_count response config_json grouped_json duplicate_count signature_count
  local avoid_json='[]' device_count=0 selected_count interactive=0 filter_size_json='null'
  local -a avoid_identifiers device_identifiers
  avoid_identifiers=()
  device_identifiers=()

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
      --device) device_identifiers+=("${2:?missing --device value}"); shift 2 ;;
      --avoid) avoid_identifiers+=("${2:?missing --avoid value}"); shift 2 ;;
      --all-matches|--auto-select) all_matches=1; shift ;;
      --non-interactive) non_interactive=1; shift ;;
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
  case "${transport}" in sas|sata|scsi|nvme|usb|any) ;; *) zfs.die "Unsupported transport filter: ${transport}" ;; esac
  case "${media}" in hdd|ssd|any) ;; *) zfs.die "Unsupported media filter: ${media}" ;; esac
  dataset="${dataset:-${pool}/data}"
  mountpoint="${mountpoint:-/media/${pool}}"
  [[ "${dataset}" == "${pool}/"* ]] || zfs.die "Dataset must be a child of pool ${pool}"
  [[ "${mountpoint}" == /* && "${mountpoint}" != "/" ]] || zfs.die "Mountpoint must be an absolute non-root path"
  [[ "${pool}" =~ ^[A-Za-z][A-Za-z0-9_.:-]*$ ]] || zfs.die "Invalid ZFS pool name: ${pool}"
  zfs.config.safe.output "${output}"

  if [[ -e "${output}" ]]; then
    ((replace == 1)) || zfs.die "${output} already exists; use --replace to create a backup"
    cp -p "${output}" "${output}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  fi

  if [[ -n "${inventory_file}" ]]; then
    inventory="$(jq -S . "${inventory_file}")"
  else
    tmp="$(mktemp)"
    zfs.inventory.collect > "${tmp}"
    inventory="$(cat "${tmp}")"
    rm -f "${tmp}"
  fi
  tmp="$(mktemp)"; printf '%s\n' "${inventory}" > "${tmp}"
  zfs.inventory.print.table "${tmp}"
  rm -f "${tmp}"

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

  candidates="$(jq -c \
    --arg transport "${transport}" --arg media "${media}" \
    --argjson minimum "${lower_requested}" --argjson maximum "${upper_requested}" --argjson use_size "$( [[ -n "${requested_size}" ]] && printf true || printf false )" \
    --argjson avoided "${avoid_json}" '
      [.disks[] |
        select(.eligible == true) |
        select($transport == "any" or ((.transport // "")|ascii_downcase) == $transport) |
        select($media == "any" or (.media // (if .rotational then "hdd" else "ssd" end)) == $media) |
        select(($use_size|not) or (.size_bytes >= $minimum and .size_bytes <= $maximum)) |
        select(([$avoided[] as $a | (.path == $a or .stable_path == $a or .wwn == $a or .serial == $a or .kernel == $a)] | any) | not)
      ] | sort_by(.stable_path)' <<< "${inventory}")"

  if [[ -n "${device_identifiers[*]-}" ]]; then
    device_count="${#device_identifiers[@]}"
  fi
  if ((device_count > 0)); then
    selected='[]'
    for identifier in "${device_identifiers[@]}"; do
      matches="$(zfs.identifier.filter <(printf '%s\n' "${inventory}") "${identifier}")"
      match_count="$(jq 'length' <<< "${matches}")"
      [[ "${match_count}" -eq 1 ]] || zfs.die "Explicit identifier must match exactly one disk: ${identifier}"
      match="$(jq -c '.[0]' <<< "${matches}")"
      if ! jq -e --arg stable "$(jq -r '.stable_path' <<< "${match}")" 'map(.stable_path) | index($stable) != null' <<< "${candidates}" >/dev/null; then
        zfs.die "Explicit device is not eligible under current filters: ${identifier}"
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

  if ((non_interactive == 0)) && [[ -r /dev/tty && -w /dev/tty ]]; then
    interactive=1
    selected="$(zfs.config.reorder.interactive "${selected}")"
    vdev_type="${vdev_type:-$(zfs.prompt "Data vdev type: mirror, raidz1, raidz2, or raidz3" "raidz2")}"
    vdev_count="${vdev_count:-$(zfs.prompt "Number of equal-width data vdevs" "1")}"
    if [[ "${vdev_count}" =~ ^[1-9][0-9]*$ ]] && ((selected_count % vdev_count == 0)); then
      per_vdev="${per_vdev:-$(zfs.prompt "Devices per vdev" "$((selected_count / vdev_count))")}"
    else
      per_vdev="${per_vdev:-$(zfs.prompt "Devices per vdev" "")}"
    fi
  else
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
      observed_fault_domain:(.fault_domain // "unknown")
    };
    [range(0;$count) as $v | {
      name:("data-"+($v|tostring)), type:$type,
      devices:[range(0;$width) as $d | device(($v*$width)+$d)]
    }]' <<< "${selected}")"

  config_json="$(jq -n -S \
    --arg pool "${pool}" --arg dataset "${dataset}" --arg mountpoint "${mountpoint}" \
    --arg transport "${transport}" --arg media "${media}" --argjson allow_wipe "${allow_signature_wipe}" \
    --argjson size_filter "${filter_size_json}" --argjson avoided "${avoid_json}" \
    --argjson tolerance "${tolerance}" --argjson vdevs "${grouped_json}" '
    {
      schema_version:1,
      generated_by:"setup/storage/zpool.config.sh",
      pool:{
        name:$pool,allow_signature_wipe:($allow_wipe==1),
        properties:{ashift:12,autotrim:"off"},
        filesystem_properties:{compression:"lz4",atime:"off",xattr:"sa",acltype:"posixacl",dnodesize:"auto",mountpoint:"none",canmount:"off"}
      },
      selection:{
        filters:{transport:(if $transport=="any" then [] else [$transport] end),media:$media,size_bytes:$size_filter,avoided:$avoided},
        expected_size_tolerance_percent:$tolerance
      },
      vdevs:$vdevs,
      datasets:[{name:$dataset,mountpoint:$mountpoint,properties:{canmount:"on",recordsize:"1M",dedup:"off"}}]
    }')"

  zfs.warn "Logical vdev grouping is not physical fault-domain isolation. Review HBAs, expanders, backplanes, and power domains."
  printf '%s\n' "${config_json}" | jq -r '
    "Pool: \(.pool.name)",
    (.vdevs[] | "\(.name) \(.type):", (.devices[] | "  \(.path) serial=\(.expected_serial) domain=\(.observed_fault_domain)")),
    (.datasets[] | "Dataset: \(.name) -> \(.mountpoint)")' >&2
  if ((interactive == 1)); then
    response="$(zfs.prompt "Type WRITE to save this editable configuration" "")"
    [[ "${response}" == "WRITE" ]] || zfs.die "Configuration write was not confirmed"
  fi

  tmp="$(mktemp)"; canonical="$(mktemp)"
  printf '%s\n' "${config_json}" > "${tmp}"
  jq -S . "${tmp}" > "${canonical}"
  zfs.config.validate.structure "${canonical}"
  zfs.write.atomic "${output}" 0600 "${canonical}"
  rm -f "${tmp}" "${canonical}"
  zfs.log "Wrote ${output}"
  zfs.config.print.topology "${output}"
}

zfs.config.print.topology() {
  local config="$1"
  jq -r '
    "Pool: \(.pool.name)",
    "Layout: \(.vdevs|length) x \(.vdevs[0].devices|length) \(.vdevs[0].type)",
    (.vdevs[] | "\(.name) \(.type):", (.devices[] | "  \(.label)  \(.path)  serial=\(.expected_serial) bytes=\(.expected_size_bytes) domain=\(.observed_fault_domain)")),
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
    (.pool.filesystem_properties.acltype == "posixacl" or .pool.filesystem_properties.acltype == "nfsv4" or .pool.filesystem_properties.acltype == "off") and
    (.pool.filesystem_properties.dnodesize | type=="string" and test("^(auto|legacy|[0-9]+[kK])$")) and
    .pool.filesystem_properties.mountpoint == "none" and
    .pool.filesystem_properties.canmount == "off" and
    (.selection.filters.transport | type=="array" and all(.[]; .=="sas" or .=="sata" or .=="scsi" or .=="nvme" or .=="usb")) and
    (.selection.filters.media == "hdd" or .selection.filters.media == "ssd" or .selection.filters.media == "any") and
    (.selection.filters.avoided | type=="array" and all(.[]; type=="string")) and
    (.selection.filters.size_bytes == null or (
      (.selection.filters.size_bytes.minimum_bytes | type=="number" and floor==. and .>0) and
      (.selection.filters.size_bytes.maximum_bytes | type=="number" and floor==. and .>0) and
      .selection.filters.size_bytes.minimum_bytes < .selection.filters.size_bytes.maximum_bytes
    )) and
    (.selection.expected_size_tolerance_percent | type == "number") and
    .selection.expected_size_tolerance_percent > 0 and
    .selection.expected_size_tolerance_percent <= 5 and
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
      (.physical_sector_bytes | type=="number" and floor==. and .>0)
    )) and
    ([.vdevs[].devices[].path] | length == (unique|length)) and
    ([.vdevs[].devices[].expected_wwn] | length == (unique|length)) and
    ([.vdevs[].devices[].expected_serial] | length == (unique|length)) and
    ([.vdevs[].devices[].label] | length == (unique|length)) and
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
  local config="$1" inventory="$2" matched="$3" allow_wipe minimum maximum use_size tolerance failures expected_count
  allow_wipe="$(jq -r '.pool.allow_signature_wipe' "${config}")"
  use_size="$(jq -r '.selection.filters.size_bytes != null' "${config}")"
  minimum="$(jq -r '.selection.filters.size_bytes.minimum_bytes // 0' "${config}")"
  maximum="$(jq -r '.selection.filters.size_bytes.maximum_bytes // 0' "${config}")"
  tolerance="$(jq -r '.selection.expected_size_tolerance_percent' "${config}")"

  failures="$(jq -r \
    --argjson minimum "${minimum}" --argjson maximum "${maximum}" --argjson tolerance "${tolerance}" \
    --argjson use_size "${use_size}" \
    --argjson allow_wipe "$( [[ "${allow_wipe}" == true ]] && printf 1 || printf 0 )" '
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
  local config="$1" inventory="$2" matched="$3" pool
  zfs.config.validate.structure "${config}"
  pool="$(jq -r '.pool.name' "${config}")"
  zfs.require.command zpool
  zfs.require.command zfs
  zfs.require.command wipefs
  if zfs.pool.exists.or.importable "${pool}"; then
    zfs.die "Pool ${pool} already exists or is importable"
  fi
  zfs.inventory.collect > "${inventory}"
  zfs.inventory.match.config "${config}" "${inventory}" "${matched}"
  zfs.preflight.validate.devices "${config}" "${inventory}" "${matched}"
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
  local config="$1" plan_file="$2" work inventory matched commands capacity payload canonical plan_id
  local config_hash config_source inventory_hash requires_wipe dry_run_json
  work="$(mktemp -d)"
  inventory="${work}/inventory.json"; matched="${work}/matched.json"; commands="${work}/commands.json"; capacity="${work}/capacity.json"
  payload="${work}/payload.json"; canonical="${work}/canonical.json"
  zfs.preflight.prepare "${config}" "${inventory}" "${matched}"
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
  inventory_hash="$(zfs.sha256 "${matched}")"
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
  local plan_file="$1" work config inventory matched expected_hash actual_hash pool config_source config_hash
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
  zfs.inventory.collect > "${inventory}"
  zfs.inventory.match.config "${config}" "${inventory}" "${matched}"
  zfs.preflight.validate.devices "${config}" "${inventory}" "${matched}"
  expected_hash="$(jq -r '.inventory_hash' "${plan_file}")"
  actual_hash="$(zfs.sha256 "${matched}")"
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
  zfs.require.command flock
  mkdir -p "${PROXMOX_ZFS_LOCK_ROOT:-/run/lock}"
  exec {ZFS_FEATURE_LOCK_FD}>"${PROXMOX_ZFS_LOCK_ROOT:-/run/lock}/proxmox-zfs-${pool}.lock"
  flock -n "${ZFS_FEATURE_LOCK_FD}" || zfs.die "Another ZFS feature operation holds the ${pool} lock"
}

zfs.signatures.wipe() {
  local plan_file="$1" plan_id="$2" confirm_pool="$3" confirmed_all="$4" pool state_dir command_json response path
  zfs.require.regular.entrypoint
  zfs.require.root
  zfs.plan.verify.id "${plan_file}" "${plan_id}"
  [[ "$(jq -r '.plan_kind' "${plan_file}")" == "signature-wipe" ]] || zfs.die "Plan does not require signature wiping"
  pool="$(jq -r '.configuration.pool.name' "${plan_file}")"
  [[ "${confirm_pool}" == "${pool}" ]] || zfs.die "--confirm-wipe must exactly match pool name ${pool}"
  zfs.lock.acquire "${pool}"
  zfs.plan.revalidate "${plan_file}"
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
  local plan_file="$1" plan_id="$2" confirm_pool="$3" mode="$4" confirmed="$5" pool state_dir command_json response
  zfs.require.regular.entrypoint
  zfs.require.root
  [[ "${mode}" == "create" ]] || zfs.die "Creation requires the explicit option --mode create"
  zfs.plan.verify.id "${plan_file}" "${plan_id}"
  [[ "$(jq -r '.plan_kind' "${plan_file}")" == "create" ]] || zfs.die "Signature-wipe plans cannot create a pool; wipe, re-inventory, and re-plan"
  [[ "$(jq -r '.requires_signature_wipe' "${plan_file}")" == false ]] || zfs.die "Creation plan still requires signature wiping"
  pool="$(jq -r '.configuration.pool.name' "${plan_file}")"
  [[ "${confirm_pool}" == "${pool}" ]] || zfs.die "--confirm-create must exactly match pool name ${pool}"
  zfs.lock.acquire "${pool}"
  zfs.plan.revalidate "${plan_file}"
  if ((confirmed != 1)); then
    [[ -r /dev/tty && -w /dev/tty ]] || zfs.die "Non-interactive creation requires --yes"
    response="$(zfs.prompt "Type yes to create pool ${pool} from plan ${plan_id}" "no")"
    [[ "${response}" == "yes" ]] || zfs.die "Pool creation was not confirmed"
  fi
  state_dir="${ZFS_DEFAULT_STATE_ROOT}/${pool}"
  mkdir -p "${state_dir}"; chmod 0700 "${state_dir}"
  cp "${plan_file}" "${state_dir}/accepted-plan.json"; chmod 0600 "${state_dir}/accepted-plan.json"
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
  zfs.verify.config <(jq -S '.configuration' "${plan_file}")
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

zfs.expect.zfs.property() {
  local dataset="$1" property="$2" expected="$3" observed
  observed="$(zfs get -H -o value "${property}" "${dataset}" 2>/dev/null | head -n1)"
  [[ "${observed}" == "${expected}" ]] || zfs.die "Dataset property ${dataset}:${property}: expected ${expected}, observed ${observed:-missing}"
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
  setup/storage/zfs.sh inventory [--output text|json] [--output-file FILE]
  setup/storage/zfs.sh validate-config [--config FILE]
  setup/storage/zfs.sh preflight [--config FILE]
  setup/storage/zfs.sh plan [--config FILE] [--plan-file FILE]
  setup/storage/zfs.sh wipe-signatures --plan-file FILE --plan-id SHA256 --mode wipe-signatures --confirm-wipe POOL [--yes]
  setup/storage/zfs.sh apply --plan-file FILE --plan-id SHA256 --mode create --confirm-create POOL [--yes]
  setup/storage/zfs.sh status --pool POOL [--output text|json]
  setup/storage/zfs.sh verify [--config FILE]
  setup/storage/zfs.sh --help

Configuration supports equal-width mirror, RAIDZ1, RAIDZ2, and RAIDZ3 data
vdevs with operator-selected whole disks. Signature wiping is a distinct
reviewed action. Creation never adds zpool -f. Plan and destructive actions are
refused from a streamed shell.
EOF
}

zfs.action.inventory() {
  local output="text" output_file="" inventory install_deps=0
  while (($#)); do
    case "$1" in
      --output) output="${2:?missing --output value}"; shift 2 ;;
      --output-file) output_file="${2:?missing --output-file value}"; shift 2 ;;
      --install-deps) install_deps=1; shift ;;
      *) zfs.die "Unknown inventory option: $1" ;;
    esac
  done
  ((install_deps == 0)) || zfs.install.dependencies
  [[ "${output}" == text || "${output}" == json ]] || zfs.die "Inventory output must be text or json"
  inventory="$(mktemp)"; zfs.inventory.collect > "${inventory}"
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
  local config="$(pwd -P)/zpool.config" work inventory matched
  while (($#)); do
    case "$1" in
      --config) config="${2:?missing --config value}"; shift 2 ;;
      *) zfs.die "Unknown preflight option: $1" ;;
    esac
  done
  zfs.require.regular.entrypoint
  work="$(mktemp -d)"; inventory="${work}/inventory.json"; matched="${work}/matched.json"
  zfs.preflight.prepare "${config}" "${inventory}" "${matched}"
  zfs.config.print.topology "${config}"
  jq -r '.[] | "\(.expected.label) ok  \(.expected.path)  serial=\(.actual.serial) bytes=\(.actual.size_bytes) transport=\(.actual.transport) signatures=\(.actual.signatures|join(","))"' "${matched}"
  rm -rf "${work}"
  zfs.log "Preflight passed"
}

zfs.action.plan() {
  local config="$(pwd -P)/zpool.config" plan_file="$(pwd -P)/zpool.plan"
  while (($#)); do
    case "$1" in
      --config) config="${2:?missing --config value}"; shift 2 ;;
      --plan-file) plan_file="${2:?missing --plan-file value}"; shift 2 ;;
      *) zfs.die "Unknown plan option: $1" ;;
    esac
  done
  zfs.require.regular.entrypoint
  [[ ! -L "${plan_file}" ]] || zfs.die "Refusing symlink plan output: ${plan_file}"
  zfs.plan.build "${config}" "${plan_file}"
}

zfs.action.wipe() {
  local plan_file="" plan_id="" mode="" confirm="" yes=0
  while (($#)); do
    case "$1" in
      --plan-file) plan_file="${2:?missing --plan-file value}"; shift 2 ;;
      --plan-id) plan_id="${2:?missing --plan-id value}"; shift 2 ;;
      --mode) mode="${2:?missing --mode value}"; shift 2 ;;
      --confirm-wipe) confirm="${2:?missing --confirm-wipe value}"; shift 2 ;;
      --yes) yes=1; shift ;;
      *) zfs.die "Unknown wipe-signatures option: $1" ;;
    esac
  done
  [[ -n "${plan_file}" && -n "${plan_id}" && -n "${confirm}" && "${mode}" == wipe-signatures ]] || \
    zfs.die "wipe-signatures requires --plan-file, --plan-id, --mode wipe-signatures, and --confirm-wipe; use --yes only for explicit all-device confirmation"
  zfs.signatures.wipe "${plan_file}" "${plan_id}" "${confirm}" "${yes}"
}

zfs.action.apply() {
  local plan_file="" plan_id="" mode="" confirm="" yes=0
  while (($#)); do
    case "$1" in
      --plan-file) plan_file="${2:?missing --plan-file value}"; shift 2 ;;
      --plan-id) plan_id="${2:?missing --plan-id value}"; shift 2 ;;
      --mode) mode="${2:?missing --mode value}"; shift 2 ;;
      --confirm-create) confirm="${2:?missing --confirm-create value}"; shift 2 ;;
      --yes) yes=1; shift ;;
      *) zfs.die "Unknown apply option: $1" ;;
    esac
  done
  [[ -n "${plan_file}" && -n "${plan_id}" && -n "${confirm}" && "${mode}" == create ]] || \
    zfs.die "apply requires --plan-file, --plan-id, --mode create, and --confirm-create; non-interactive use also requires --yes"
  zfs.pool.apply "${plan_file}" "${plan_id}" "${confirm}" "${mode}" "${yes}"
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
