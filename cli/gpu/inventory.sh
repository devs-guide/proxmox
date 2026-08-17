#!/usr/bin/env bash
# Canonical all-GPU PCI inventory and explicit selection helpers.

INVENTORY_JSON='{"gpus":[]}'
SELECTED_GPU_JSON='null'

gpu.inventory_vm_assignments() {
  local slot="$1" qm_slot="${1#0000:}" config_file="" owner="" line="" assignments='[]'
  [[ -d "${PVE_ROOT}/qemu-server" ]] || { printf '%s\n' "${assignments}"; return; }
  shopt -s nullglob
  for config_file in "${PVE_ROOT}/qemu-server/"*.conf; do
    owner="$(basename "${config_file}" .conf)"
    while IFS= read -r line; do
      case "${line}" in
        hostpci*:*"${slot}"*|hostpci*:*"${qm_slot}"*)
          assignments="$(jq -c --arg vmid "${owner}" --arg value "${line}" \
            '. + [{vmid:($vmid|tonumber),value:$value}]' <<< "${assignments}")"
          ;;
      esac
    done < "${config_file}"
  done
  shopt -u nullglob
  printf '%s\n' "${assignments}"
}

gpu.function_json() {
  local bdf="$1" group="" driver="" subsystem_vendor="" subsystem_device="" numa=""
  group="$(gpu.device_group "${bdf}" || true)"
  driver="$(gpu.device_driver "${bdf}")"
  subsystem_vendor="$(gpu.sysfs_value "${bdf}" subsystem_vendor '')"
  subsystem_device="$(gpu.sysfs_value "${bdf}" subsystem_device '')"
  numa="$(gpu.sysfs_value "${bdf}" numa_node '')"
  jq -cn \
    --arg bdf "${bdf}" \
    --arg class "$(gpu.sysfs_value "${bdf}" class unknown)" \
    --arg vendor "$(gpu.sysfs_value "${bdf}" vendor unknown)" \
    --arg device "$(gpu.sysfs_value "${bdf}" device unknown)" \
    --arg subsystem_vendor "${subsystem_vendor}" \
    --arg subsystem_device "${subsystem_device}" \
    --arg driver "${driver}" \
    --arg iommu_group "${group}" \
    --arg numa_node "${numa}" \
    --arg boot_vga "$(gpu.sysfs_value "${bdf}" boot_vga 0)" \
    --arg reset_supported "$([[ -e "${SYSFS_ROOT}/bus/pci/devices/${bdf}/reset" ]] && printf 1 || printf 0)" \
    '{bdf:$bdf,class:$class,vendor_id:$vendor,device_id:$device,
      subsystem_vendor_id:(if $subsystem_vendor=="" then null else $subsystem_vendor end),
      subsystem_device_id:(if $subsystem_device=="" then null else $subsystem_device end),
      driver:$driver,iommu_group:(if $iommu_group=="" then null else $iommu_group end),
      numa_node:(if $numa_node=="" or $numa_node=="-1" then null else ($numa_node|tonumber) end),
      boot_vga:($boot_vga=="1"),reset_supported:($reset_supported=="1")}'
}

gpu.capture_inventory() {
  local path="" bdf="" class="" slot="" seen="" function_path="" function_bdf=""
  local functions='[]' displays='[]' gpus='[]' assignments='[]'
  local -a function_paths=()

  shopt -s nullglob
  for path in "${SYSFS_ROOT}/bus/pci/devices/"*; do
    bdf="$(basename "${path}")"
    class="$(gpu.sysfs_value "${bdf}" class unknown)"
    [[ "${class}" == 0x03* ]] || continue
    slot="${bdf%.*}"
    [[ " ${seen} " != *" ${slot} "* ]] || continue
    seen="${seen:+${seen} }${slot}"
    function_paths=("${SYSFS_ROOT}/bus/pci/devices/${slot}."*)
    functions='[]'
    displays='[]'
    while IFS= read -r function_path; do
      [[ -n "${function_path}" ]] || continue
      function_bdf="$(basename "${function_path}")"
      functions="$(jq -c --argjson item "$(gpu.function_json "${function_bdf}")" \
        '. + [$item]' <<< "${functions}")"
      [[ "$(gpu.sysfs_value "${function_bdf}" class unknown)" == 0x03* ]] \
        && displays="$(jq -c --arg bdf "${function_bdf}" '. + [$bdf]' <<< "${displays}")"
    done < <(printf '%s\n' "${function_paths[@]}" | sort)
    assignments="$(gpu.inventory_vm_assignments "${slot}")"
    gpus="$(jq -c \
      --arg slot "${slot}" \
      --argjson display_bdfs "${displays}" \
      --argjson functions "${functions}" \
      --argjson vm_assignments "${assignments}" \
      '. + [{slot:$slot,display_bdfs:$display_bdfs,functions:$functions,
              boot_vga:($functions|any(.boot_vga)),
              reset_supported:($functions|all(.reset_supported)),
              vm_assignments:$vm_assignments}]' <<< "${gpus}")"
  done
  shopt -u nullglob
  INVENTORY_JSON="$(jq -cn --argjson gpus "${gpus}" '{gpus:$gpus}')"
}

gpu.normalize_bdf() {
  local value=""
  value="$(printf '%s' "${GPU_INPUT}" | tr '[:upper:]' '[:lower:]')"
  [[ -n "${value}" ]] || gpu.die "${GPU_EXIT_USAGE}" "--gpu is required for ${ACTION}"
  [[ "${value}" =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && value="0000:${value}"
  [[ "${value}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] \
    || gpu.die "${GPU_EXIT_USAGE}" \
      "--gpu must be a function-qualified PCI BDF, not a slot: ${GPU_INPUT}"
  GPU_BDF="${value}"
  GPU_SLOT="${value%.*}"
  GPU_QM_SLOT="${GPU_SLOT#0000:}"
}

gpu.select_inventory_bdf() {
  local GPU_BDF_ENTRY=""
  SELECTED_GPU_JSON="$(jq -c --arg bdf "${GPU_BDF}" '
    first(.gpus[] | select(any(.display_bdfs[]; . == $bdf))) // null
    | if . == null then null else . + {selected_bdf:$bdf} end
  ' <<< "${INVENTORY_JSON}")"
  [[ "${SELECTED_GPU_JSON}" != null ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" \
    "selected display function ${GPU_BDF} is absent from complete live inventory"
  GPU_SLOT="$(jq -r '.slot' <<< "${SELECTED_GPU_JSON}")"
  GPU_QM_SLOT="${GPU_SLOT#0000:}"
  GPU_FUNCTIONS=()
  while IFS= read -r GPU_BDF_ENTRY; do
    [[ -n "${GPU_BDF_ENTRY}" ]] && GPU_FUNCTIONS+=("${GPU_BDF_ENTRY}")
  done < <(jq -r '.functions[].bdf' <<< "${SELECTED_GPU_JSON}")
}

gpu.discover_functions() {
  gpu.capture_inventory
  gpu.select_inventory_bdf
}

gpu.render_selected_json() {
  [[ "${SELECTED_GPU_JSON}" != null ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" \
    "no inventory-backed GPU selection is active"
  jq -c '.functions' <<< "${SELECTED_GPU_JSON}"
}

gpu.load_state_selection() {
  local file="$1" function_records='[]' stored_bdf="" stored_slot="" GPU_BDF_ENTRY=""
  [[ -r "${file}" ]] || return 1
  gpu.state_is_json "${file}" || return 1
  stored_bdf="$(jq -r '.gpu_bdf // empty' "${file}" 2>/dev/null)"
  stored_slot="$(jq -r '.gpu_slot // empty' "${file}" 2>/dev/null)"
  function_records="$(jq -c '.gpu_function_records // []' "${file}" 2>/dev/null)"
  [[ "${stored_bdf}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]
  [[ "${stored_slot}" == "${stored_bdf%.*}" ]]
  jq -e --arg bdf "${stored_bdf}" --arg slot "${stored_slot}" '
    length > 0
    and any(.[]; .bdf == $bdf and (.class | startswith("0x03")))
    and all(.[]; (.bdf | startswith($slot + ".")))
  ' <<< "${function_records}" >/dev/null || return 1
  GPU_INPUT="${stored_bdf}"
  GPU_BDF="${stored_bdf}"
  GPU_SLOT="${stored_slot}"
  GPU_QM_SLOT="${stored_slot#0000:}"
  SELECTED_GPU_JSON="$(jq -cn \
    --arg slot "${stored_slot}" \
    --arg selected_bdf "${stored_bdf}" \
    --argjson functions "${function_records}" \
    '{slot:$slot,selected_bdf:$selected_bdf,
      display_bdfs:[$selected_bdf],functions:$functions,
      boot_vga:($functions|any(.boot_vga)),
      reset_supported:($functions|all(.reset_supported)),vm_assignments:[]}')"
  GPU_FUNCTIONS=()
  while IFS= read -r GPU_BDF_ENTRY; do
    [[ -n "${GPU_BDF_ENTRY}" ]] && GPU_FUNCTIONS+=("${GPU_BDF_ENTRY}")
  done < <(jq -r '.[].bdf' <<< "${function_records}")
}

gpu.discover_or_restore_functions() {
  local state_file="$1"
  gpu.capture_inventory
  if [[ -n "${GPU_INPUT}" ]]; then
    gpu.normalize_bdf
    if jq -e --arg bdf "${GPU_BDF}" \
      'any(.gpus[]; any(.display_bdfs[]; . == $bdf))' \
      <<< "${INVENTORY_JSON}" >/dev/null; then
      gpu.select_inventory_bdf
      return
    fi
  fi
  gpu.load_state_selection "${state_file}" || gpu.die "${GPU_EXIT_PREFLIGHT}" \
    "live inventory cannot prove the GPU and managed state lacks schema-v3 identity records"
}
