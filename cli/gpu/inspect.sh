#!/usr/bin/env bash
# Read-only GPU inventory, preflight, status, and verification runner.
set -euo pipefail

GPU_COMPONENT="cli.gpu.inspect"
CLI_ROOT="${PROXMOX_GPU_CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=cli/gpu/common.sh
source "${CLI_ROOT}/gpu/common.sh"

GPU_VENDOR=""
GPU_CLASS=""
IOMMU_READY=0
PREFLIGHT_READY=0
PREFLIGHT_REASON=""
SELECTED_HOSTPCI_INDEX=""

gpu.vendor_name() {
  case "$1" in
    0x1002) printf 'amd\n' ;;
    0x10de) printf 'nvidia\n' ;;
    *) printf 'unsupported\n' ;;
  esac
}

gpu.is_selected_function() {
  local candidate="$1" bdf=""
  for bdf in "${GPU_FUNCTIONS[@]}"; do [[ "${candidate}" == "${bdf}" ]] && return 0; done
  return 1
}

gpu.validate_groups() {
  local allow_missing="${1:-0}" bdf="" group="" member_path="" member="" class="" groups=""
  IOMMU_READY=1
  for bdf in "${GPU_FUNCTIONS[@]}"; do
    group="$(gpu.device_group "${bdf}" || true)"
    if [[ -z "${group}" ]]; then
      IOMMU_READY=0
      ((allow_missing == 1)) && continue
      gpu.die "${GPU_EXIT_PREFLIGHT}" "${bdf} has no active IOMMU group"
    fi
    [[ " ${groups} " == *" ${group} "* ]] || groups="${groups:+${groups} }${group}"
  done
  for group in ${groups}; do
    [[ -d "${SYSFS_ROOT}/kernel/iommu_groups/${group}/devices" ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "IOMMU group ${group} has no device directory"
    shopt -s nullglob
    for member_path in "${SYSFS_ROOT}/kernel/iommu_groups/${group}/devices/"*; do
      member="$(basename "${member_path}")"
      gpu.is_selected_function "${member}" && continue
      class="$(gpu.sysfs_value "${member}" class unknown)"
      [[ "${class}" == 0x0604* ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "IOMMU group ${group} contains unrelated endpoint ${member} (${class})"
    done
    shopt -u nullglob
  done
}

gpu.validate_gpu_identity() {
  GPU_CLASS="$(gpu.sysfs_value "${GPU_BDF}" class unknown)"
  [[ "${GPU_CLASS}" == 0x03* ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "${GPU_BDF} is not a VGA, 3D, or display controller (${GPU_CLASS})"
  GPU_VENDOR="$(gpu.vendor_name "$(gpu.sysfs_value "${GPU_BDF}" vendor unknown)")"
  [[ "${GPU_VENDOR}" != unsupported ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "only AMD and NVIDIA whole-GPU passthrough is supported"
  if [[ "${PROFILE}" == macos-desktop && "${GPU_VENDOR}" == nvidia ]]; then
    gpu.die "${GPU_EXIT_PREFLIGHT}" "NVIDIA GPUs are not supported by the macOS desktop profile"
  fi
}

gpu.is_boot_vga() {
  local bdf=""
  for bdf in "${GPU_FUNCTIONS[@]}"; do
    [[ "$(gpu.sysfs_value "${bdf}" boot_vga 0)" == 1 ]] && return 0
  done
  return 1
}

gpu.validate_vm() {
  local require_stopped="${1:-1}" config="" status="" ha=""
  [[ -n "${VM_ID}" ]] || gpu.die "${GPU_EXIT_USAGE}" "--vm is required for ${ACTION}"
  config="$(qm config "${VM_ID}" 2>/dev/null)" || gpu.die "${GPU_EXIT_PREFLIGHT}" "VM ${VM_ID} does not exist on this node"
  status="$(qm status "${VM_ID}" 2>/dev/null || true)"
  if ((require_stopped == 1)); then
    [[ "${status}" == *'status: stopped'* ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "VM ${VM_ID} must be stopped"
  else
    [[ "${status}" == *'status: stopped'* || "${status}" == *'status: running'* ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "VM ${VM_ID} status is unavailable"
  fi
  printf '%s\n' "${config}" | grep -Eq '^machine: (pc-)?q35([,-]|$)' || gpu.die "${GPU_EXIT_PREFLIGHT}" "VM ${VM_ID} must use Q35"
  printf '%s\n' "${config}" | grep -q '^template: 1$' && gpu.die "${GPU_EXIT_PREFLIGHT}" "VM ${VM_ID} is a template"
  printf '%s\n' "${config}" | grep -q '^lock:' && gpu.die "${GPU_EXIT_PREFLIGHT}" "VM ${VM_ID} is locked"
  if [[ "${PROFILE}" != linux-compute ]]; then
    printf '%s\n' "${config}" | grep -q '^bios: ovmf$' || gpu.die "${GPU_EXIT_PREFLIGHT}" "${PROFILE} requires OVMF"
    printf '%s\n' "${config}" | grep -q '^efidisk0:' || gpu.die "${GPU_EXIT_PREFLIGHT}" "${PROFILE} requires an EFI disk"
  fi
  if gpu.command_exists ha-manager; then
    ha="$(ha-manager config 2>/dev/null || true)"
    printf '%s\n' "${ha}" | grep -Eq "^[[:space:]]*vm:${VM_ID}([[:space:]]|$)" && gpu.die "${GPU_EXIT_PREFLIGHT}" "VM ${VM_ID} is HA-managed"
  fi
  return 0
}

gpu.validate_vm_stopped_only() {
  [[ -n "${VM_ID}" ]] || gpu.die "${GPU_EXIT_USAGE}" "--vm is required for ${ACTION}"
  qm config "${VM_ID}" >/dev/null 2>&1 || gpu.die "${GPU_EXIT_PREFLIGHT}" "VM ${VM_ID} does not exist on this node"
  [[ "$(qm status "${VM_ID}" 2>/dev/null || true)" == *'status: stopped'* ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "VM ${VM_ID} must be stopped"
}

gpu.validate_assignment_conflicts() {
  local config_file="" line="" owner="" qemu_dir="${PVE_ROOT}/qemu-server"
  [[ -d "${qemu_dir}" ]] || return 0
  shopt -s nullglob
  for config_file in "${qemu_dir}/"*.conf; do
    owner="$(basename "${config_file}" .conf)"
    [[ "${owner}" == "${VM_ID}" ]] && continue
    while IFS= read -r line; do
      case "${line}" in
        hostpci*:*"${GPU_QM_SLOT}"*|hostpci*:*"${GPU_SLOT}"*) gpu.die "${GPU_EXIT_PREFLIGHT}" "GPU ${GPU_QM_SLOT} is already referenced by VM ${owner}: ${line}" ;;
      esac
    done < "${config_file}"
  done
  shopt -u nullglob
}

gpu.choose_hostpci() {
  local config="$1" index=""
  if [[ "${HOSTPCI_INDEX}" != auto ]]; then
    printf '%s\n' "${config}" | grep -q "^hostpci${HOSTPCI_INDEX}:" && gpu.die "${GPU_EXIT_PREFLIGHT}" "hostpci${HOSTPCI_INDEX} is occupied"
    printf '%s\n' "${HOSTPCI_INDEX}"
    return
  fi
  for index in $(seq 0 15); do
    if ! printf '%s\n' "${config}" | grep -q "^hostpci${index}:"; then printf '%s\n' "${index}"; return; fi
  done
  gpu.die "${GPU_EXIT_PREFLIGHT}" "VM ${VM_ID} has no free hostpci0..15 slot"
}

gpu.preflight_selected() {
  local allow_missing_iommu="${1:-0}" allow_running="${2:-0}" select_hostpci="${3:-1}" config="" bdf=""
  gpu.normalize_bdf
  gpu.discover_functions
  gpu.validate_gpu_identity
  gpu.validate_groups "${allow_missing_iommu}"
  gpu.validate_assignment_conflicts
  [[ -z "${VM_ID}" ]] || gpu.validate_vm "$((allow_running == 1 ? 0 : 1))"
  if gpu.is_boot_vga && ((ALLOW_HOST_DISPLAY_LOSS == 0)); then
    gpu.die "${GPU_EXIT_PREFLIGHT}" "${GPU_SLOT} is boot_vga; acknowledge tested out-of-band access with --allow-host-display-loss"
  fi
  if [[ -n "${VM_ID}" && "${select_hostpci}" == 1 ]]; then
    config="$(qm config "${VM_ID}")"
    SELECTED_HOSTPCI_INDEX="$(gpu.choose_hostpci "${config}")"
  fi
  if ((BLACKLIST_HOST_DRIVERS == 1)); then
    ((ALLOW_HOST_DISPLAY_LOSS == 1 && YES == 1)) || gpu.die "${GPU_EXIT_PREFLIGHT}" "blacklisting requires --allow-host-display-loss --yes"
    gpu.validate_blacklist_collateral
  fi
  if [[ "${ACTION}" == attach && "${BINDING_EFFECTIVE}" == early ]]; then
    for bdf in "${GPU_FUNCTIONS[@]}"; do
      [[ "$(gpu.device_driver "${bdf}")" == vfio-pci ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "${bdf} is not bound to vfio-pci; run verify after the required reboot"
    done
  fi
  PREFLIGHT_READY=1
}

gpu.validate_blacklist_collateral() {
  local path="" bdf="" vendor=""
  shopt -s nullglob
  for path in "${SYSFS_ROOT}/bus/pci/devices/"*; do
    bdf="$(basename "${path}")"
    gpu.is_selected_function "${bdf}" && continue
    [[ "$(gpu.sysfs_value "${bdf}" class unknown)" == 0x03* ]] || continue
    vendor="$(gpu.vendor_name "$(gpu.sysfs_value "${bdf}" vendor unknown)")"
    [[ "${vendor}" != "${GPU_VENDOR}" ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "refusing ${GPU_VENDOR} blacklist: unselected GPU ${bdf} uses the same host driver family"
  done
  shopt -u nullglob
}

gpu.inventory() {
  gpu.capture_inventory
  if [[ "${OUTPUT}" == json ]]; then
    jq -cn \
      --argjson platform "${PLATFORM_JSON}" \
      --argjson adapter "${ADAPTER_JSON}" \
      --argjson inventory "${INVENTORY_JSON}" \
      '{schema_version:3,action:"inventory",platform:$platform,adapter:$adapter,
        inventory:$inventory,result:{state:"ok"}}'
  else
    gpu.log "detected adapter: $(jq -r '.id' <<< "${ADAPTER_JSON}") (PVE ${PVE_VERSION})"
    jq -r '.gpus[] | "\(.slot) displays=\(.display_bdfs|join(",")) functions=\(.functions|length) boot_vga=\(.boot_vga) assignments=\(.vm_assignments|length)"' <<< "${INVENTORY_JSON}"
  fi
}

gpu.verify_selected() {
  local bdf="" driver="" failures=0 host_state="${STATE_ROOT}/host.state" state_binding=""
  gpu.preflight_selected 0 1 0
  state_binding="$(gpu.state_value binding_strategy "${host_state}" || true)"
  [[ -n "${state_binding}" ]] || state_binding="${BINDING_EFFECTIVE}"
  if [[ "${state_binding}" == early ]]; then
    for bdf in "${GPU_FUNCTIONS[@]}"; do
      driver="$(gpu.device_driver "${bdf}")"
      [[ "${driver}" == vfio-pci ]] || { gpu.warn "${bdf}: expected vfio-pci, found ${driver}"; failures=$((failures + 1)); }
    done
  elif [[ -n "${VM_ID}" && "$(qm status "${VM_ID}" 2>/dev/null || true)" == *'status: running'* ]]; then
    for bdf in "${GPU_FUNCTIONS[@]}"; do
      [[ "$(gpu.device_driver "${bdf}")" == vfio-pci ]] || failures=$((failures + 1))
    done
  fi
  ((failures == 0)) || gpu.die "${GPU_EXIT_PREFLIGHT}" "verification failed with ${failures} device ownership error(s)"
}

gpu.status() {
  local host_state="${STATE_ROOT}/host.state" prepared=false configured="" functions='[]'
  [[ -r "${host_state}" ]] && prepared=true
  configured="$(gpu.state_value gpu_slot "${host_state}" || true)"
  gpu.capture_inventory
  if [[ -n "${GPU_INPUT}" ]]; then
    gpu.normalize_bdf
    gpu.select_inventory_bdf
    functions="$(gpu.render_selected_json)"
  fi
  if [[ "${OUTPUT}" == json ]]; then
    jq -cn \
      --argjson platform "${PLATFORM_JSON}" \
      --argjson adapter "${ADAPTER_JSON}" \
      --argjson inventory "${INVENTORY_JSON}" \
      --argjson prepared "${prepared}" \
      --arg configured "${configured}" \
      --arg requested "${GPU_BDF}" \
      --argjson functions "${functions}" \
      '{schema_version:3,action:"status",platform:$platform,adapter:$adapter,
        inventory:$inventory,
        facts:{prepared:$prepared,
          configured_gpu:(if $configured=="" then null else $configured end),
          requested_gpu:(if $requested=="" then null else $requested end),
          functions:$functions},result:{state:"ok"}}'
  else
    gpu.log "detected adapter: $(jq -r '.id' <<< "${ADAPTER_JSON}")"
    gpu.log "managed host GPU: ${configured:-none}"
    jq -r '.[] | "\(.bdf): driver=\(.driver) iommu_group=\(.iommu_group // "none")"' <<< "${functions}"
  fi
}

gpu.inspect_main() {
  gpu.parse_args "$@"
  gpu.require_root
  gpu.require_commands jq sed grep sort readlink basename qm pveversion
  gpu.detect_release
  case "${ACTION}" in
    inventory) gpu.inventory ;;
    status) gpu.status ;;
    preflight)
      gpu.preflight_selected 0
      if [[ "${OUTPUT}" == json ]]; then
        jq -cn \
          --argjson platform "${PLATFORM_JSON}" \
          --argjson adapter "${ADAPTER_JSON}" \
          --argjson inventory "${INVENTORY_JSON}" \
          --argjson selection "${SELECTED_GPU_JSON}" \
          --arg binding "${BINDING_EFFECTIVE}" \
          --arg vendor "${GPU_VENDOR}" \
          --arg vm "${VM_ID}" \
          --arg hostpci "${SELECTED_HOSTPCI_INDEX}" \
          '{schema_version:3,action:"preflight",platform:$platform,adapter:$adapter,
            inventory:$inventory,selection:$selection,
            effective_features:{binding:$binding},
            facts:{vendor:$vendor,vmid:(if $vm=="" then null else ($vm|tonumber) end),
              hostpci_index:(if $hostpci=="" then null else ($hostpci|tonumber) end)},
            result:{state:"ready",ready:true}}'
      else
        gpu.log "preflight passed: ${GPU_SLOT} (${GPU_VENDOR}), binding=${BINDING_EFFECTIVE}${VM_ID:+, vm=${VM_ID}, hostpci${SELECTED_HOSTPCI_INDEX}}"
      fi
      ;;
    verify)
      gpu.verify_selected
      if [[ "${OUTPUT}" == json ]]; then
        jq -cn \
          --argjson platform "${PLATFORM_JSON}" \
          --argjson adapter "${ADAPTER_JSON}" \
          --argjson inventory "${INVENTORY_JSON}" \
          --argjson selection "${SELECTED_GPU_JSON}" \
          --arg binding "${BINDING_EFFECTIVE}" \
          --arg vm "${VM_ID}" \
          '{schema_version:3,action:"verify",platform:$platform,adapter:$adapter,
            inventory:$inventory,selection:$selection,
            effective_features:{binding:$binding},
            facts:{vmid:(if $vm=="" then null else ($vm|tonumber) end)},
            result:{state:"ready",ready:true}}'
      else
        gpu.log "verification passed for ${GPU_SLOT}"
      fi
      ;;
    *) gpu.die "${GPU_EXIT_USAGE}" "${ACTION} is not a read-only action" ;;
  esac
}

if [[ "${PROXMOX_GPU_INSPECT_LIBRARY:-0}" != 1 ]]; then
  gpu.inspect_main "$@"
fi
