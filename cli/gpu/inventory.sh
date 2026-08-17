#!/usr/bin/env bash
# Canonical all-GPU PCI inventory and explicit selection helpers.

INVENTORY_JSON='{"gpus":[]}'
SELECTED_GPU_JSON='null'

gpu.vendor_name() {
  case "$1" in
    0x1002) printf 'amd\n' ;;
    0x10de) printf 'nvidia\n' ;;
    *) printf 'unsupported\n' ;;
  esac
}

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
  value="$(gpu.normalize_bdf_value "${GPU_INPUT}")"
  GPU_BDF="${value}"
  GPU_SLOT="${value%.*}"
  GPU_QM_SLOT="${GPU_SLOT#0000:}"
}

gpu.normalize_bdf_value() {
  local input="$1" value=""
  value="$(printf '%s' "${input}" | tr '[:upper:]' '[:lower:]')"
  [[ -n "${value}" ]] || gpu.die "${GPU_EXIT_USAGE}" "--gpu is required for ${ACTION}"
  [[ "${value}" =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && value="0000:${value}"
  [[ "${value}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] \
    || gpu.die "${GPU_EXIT_USAGE}" \
      "GPU selectors must be function-qualified PCI BDFs, not slots: ${input}"
  printf '%s\n' "${value}"
}

gpu.inventory_vendor_gpus() {
  local vendor="$1" vendor_id=""
  case "${vendor}" in amd) vendor_id=0x1002 ;; nvidia) vendor_id=0x10de ;; *) return 1 ;; esac
  jq -c --arg vendor_id "${vendor_id}" '[.gpus[] |
    .display_bdfs as $display_bdfs |
    select(any(.functions[]; .vendor_id == $vendor_id and (.bdf as $bdf | $display_bdfs | index($bdf) != null))) |
    . + {selected_bdf:.display_bdfs[0]}]' <<< "${INVENTORY_JSON}"
}

gpu.blacklist_spec_json() {
  local normalized='{}' vendor="" value_type="" value="" input="" bdf="" values='[]'
  case "${BLACKLIST_INPUT_MODE}" in
    all) printf '%s\n' '{"amd":"all","nvidia":"all"}'; return ;;
    vendor)
      if ((${#BLACKLIST_GPU_INPUTS[@]} == 0)); then
        jq -cn --arg vendor "${BLACKLIST_VENDOR_INPUT}" '{($vendor):"all"}'
        return
      fi
      for input in "${BLACKLIST_GPU_INPUTS[@]}"; do
        bdf="$(gpu.normalize_bdf_value "${input}")" || exit "$?"
        values="$(jq -c --arg bdf "${bdf}" '. + [$bdf]' <<< "${values}")"
      done
      jq -cn --arg vendor "${BLACKLIST_VENDOR_INPUT}" --argjson values "${values}" '{($vendor):$values}'
      return
      ;;
    json)
      jq -e 'type == "object" and length > 0' <<< "${BLACKLIST_JSON_INPUT}" >/dev/null 2>&1 \
        || gpu.die "${GPU_EXIT_USAGE}" "--blacklist JSON must be a non-empty object"
      jq -e '([keys[] | ascii_downcase] | length) == ([keys[] | ascii_downcase] | unique | length)' \
        <<< "${BLACKLIST_JSON_INPUT}" >/dev/null 2>&1 \
        || gpu.die "${GPU_EXIT_USAGE}" "--blacklist JSON contains duplicate vendor keys after case normalization"
      while IFS= read -r vendor; do
        vendor="${vendor,,}"
        [[ "${vendor}" == amd || "${vendor}" == nvidia ]] \
          || gpu.die "${GPU_EXIT_USAGE}" "--blacklist JSON supports only amd and nvidia keys"
      done < <(jq -r 'keys[]' <<< "${BLACKLIST_JSON_INPUT}")
      for vendor in amd nvidia; do
        jq -e --arg vendor "${vendor}" 'with_entries(.key |= ascii_downcase) | has($vendor)' \
          <<< "${BLACKLIST_JSON_INPUT}" >/dev/null || continue
        value_type="$(jq -r --arg vendor "${vendor}" 'with_entries(.key |= ascii_downcase) | .[$vendor] | type' <<< "${BLACKLIST_JSON_INPUT}")"
        if [[ "${value_type}" == string ]]; then
          value="$(jq -r --arg vendor "${vendor}" 'with_entries(.key |= ascii_downcase) | .[$vendor] | ascii_downcase' <<< "${BLACKLIST_JSON_INPUT}")"
          [[ "${value}" == all ]] || gpu.die "${GPU_EXIT_USAGE}" "${vendor} blacklist string must be all"
          normalized="$(jq -c --arg vendor "${vendor}" '. + {($vendor):"all"}' <<< "${normalized}")"
        elif [[ "${value_type}" == array ]]; then
          jq -e --arg vendor "${vendor}" \
            'with_entries(.key |= ascii_downcase) | .[$vendor] | length > 0 and all(.[]; type == "string")' \
            <<< "${BLACKLIST_JSON_INPUT}" >/dev/null \
            || gpu.die "${GPU_EXIT_USAGE}" "${vendor} blacklist array must contain only non-empty BDF strings"
          values='[]'
          while IFS= read -r input; do
            [[ -n "${input}" ]] || gpu.die "${GPU_EXIT_USAGE}" "${vendor} blacklist array cannot contain empty values"
            bdf="$(gpu.normalize_bdf_value "${input}")" || exit "$?"
            jq -e --arg bdf "${bdf}" 'index($bdf) == null' <<< "${values}" >/dev/null \
              || gpu.die "${GPU_EXIT_USAGE}" "duplicate blacklist GPU after normalization: ${bdf}"
            values="$(jq -c --arg bdf "${bdf}" '. + [$bdf]' <<< "${values}")"
          done < <(jq -r --arg vendor "${vendor}" 'with_entries(.key |= ascii_downcase) | .[$vendor][] | select(type == "string")' <<< "${BLACKLIST_JSON_INPUT}")
          [[ "$(jq -r 'length' <<< "${values}")" -gt 0 ]] || gpu.die "${GPU_EXIT_USAGE}" "${vendor} blacklist array must be non-empty strings"
          normalized="$(jq -c --arg vendor "${vendor}" --argjson values "${values}" '. + {($vendor):$values}' <<< "${normalized}")"
        else
          gpu.die "${GPU_EXIT_USAGE}" "${vendor} blacklist value must be all or an array"
        fi
      done
      printf '%s\n' "${normalized}"
      return
      ;;
    *) gpu.die "${GPU_EXIT_USAGE}" "multi-GPU blacklist selection is not active" ;;
  esac
}

gpu.resolve_blacklist_selection() {
  local spec='{}' vendor="" requested_type="" vendor_gpus='[]' selected='[]' combined='[]'
  local requested_vendors='[]' effective='[]' exact_only='[]' requested_bdfs='[]' affected='[]'
  local affected_slots='[]' affected_functions='[]'
  local bdf="" record='null' selected_count=0 available_count=0

  gpu.capture_inventory
  spec="$(gpu.blacklist_spec_json)"
  for vendor in amd nvidia; do
    jq -e --arg vendor "${vendor}" 'has($vendor)' <<< "${spec}" >/dev/null || continue
    vendor_gpus="$(gpu.inventory_vendor_gpus "${vendor}")"
    available_count="$(jq -r 'length' <<< "${vendor_gpus}")"
    if ((available_count == 0)); then
      [[ "${BLACKLIST_INPUT_MODE}" == all ]] && continue
      gpu.die "${GPU_EXIT_PREFLIGHT}" "no ${vendor} display GPUs exist in live inventory"
    fi
    requested_vendors="$(jq -c --arg vendor "${vendor}" '. + [$vendor]' <<< "${requested_vendors}")"
    requested_type="$(jq -r --arg vendor "${vendor}" '.[$vendor] | type' <<< "${spec}")"
    if [[ "${requested_type}" == string ]]; then
      selected="${vendor_gpus}"
      effective="$(jq -c --arg vendor "${vendor}" '. + [$vendor]' <<< "${effective}")"
    else
      selected='[]'
      while IFS= read -r bdf; do
        requested_bdfs="$(jq -c --arg bdf "${bdf}" '. + [$bdf]' <<< "${requested_bdfs}")"
        record="$(jq -c --arg bdf "${bdf}" 'first(.[] | select(.selected_bdf == $bdf)) // null' <<< "${vendor_gpus}")"
        [[ "${record}" != null ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "${bdf} is not an inventoried ${vendor} display GPU"
        selected="$(jq -c --argjson record "${record}" '. + [$record]' <<< "${selected}")"
      done < <(jq -r --arg vendor "${vendor}" '.[$vendor][]' <<< "${spec}")
      selected_count="$(jq -r 'length' <<< "${selected}")"
      if ((selected_count == available_count)); then
        effective="$(jq -c --arg vendor "${vendor}" '. + [$vendor]' <<< "${effective}")"
      else
        exact_only="$(jq -c --arg vendor "${vendor}" '. + [$vendor]' <<< "${exact_only}")"
      fi
    fi
    combined="$(jq -c --argjson selected "${selected}" '. + $selected | unique_by(.slot) | sort_by(.slot)' <<< "${combined}")"
  done
  [[ "$(jq -r 'length' <<< "${combined}")" -gt 0 ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "blacklist selection resolved no supported GPUs"
  affected="$(jq -c '[.[].selected_bdf] | sort' <<< "${combined}")"
  affected_slots="$(jq -c '[.[].slot] | unique | sort' <<< "${combined}")"
  affected_functions="$(jq -c '[.[].functions[].bdf] | unique | sort' <<< "${combined}")"
  SELECTED_GPU_JSON="$(jq -c 'if length == 1 then .[0] else null end' <<< "${combined}")"
  SELECTION_SET_JSON="$(jq -cn --argjson gpus "${combined}" '{mode:(if ($gpus|length)==1 then "single" else "host-set" end),gpus:$gpus,slots:([$gpus[].slot]|unique|sort),display_bdfs:([$gpus[].display_bdfs[]]|unique|sort),functions:([$gpus[].functions[]]|unique_by(.bdf)|sort_by(.bdf))}')"
  BLACKLIST_POLICY_JSON="$(jq -cn --arg mode "${BLACKLIST_INPUT_MODE}" --argjson requested_vendors "${requested_vendors}" --argjson effective "${effective}" --argjson exact_only "${exact_only}" --argjson requested_bdfs "${requested_bdfs}" --argjson affected "${affected}" --argjson affected_slots "${affected_slots}" --argjson affected_functions "${affected_functions}" '{requested:true,input_mode:$mode,requested_vendors:$requested_vendors,effective_vendors:$effective,exact_bind_only_vendors:$exact_only,requested_bdfs:$requested_bdfs,affected_bdfs:$affected,affected_slots:$affected_slots,affected_function_bdfs:$affected_functions}')"
  GPU_FUNCTIONS=()
  SELECTED_GPU_SLOTS=()
  while IFS= read -r bdf; do [[ -n "${bdf}" ]] && GPU_FUNCTIONS+=("${bdf}"); done < <(jq -r '.functions[].bdf' <<< "${SELECTION_SET_JSON}")
  while IFS= read -r bdf; do [[ -n "${bdf}" ]] && SELECTED_GPU_SLOTS+=("${bdf}"); done < <(jq -r '.slots[]' <<< "${SELECTION_SET_JSON}")
  if [[ "${SELECTED_GPU_JSON}" != null ]]; then
    GPU_BDF="$(jq -r '.selected_bdf' <<< "${SELECTED_GPU_JSON}")"
    GPU_SLOT="$(jq -r '.slot' <<< "${SELECTED_GPU_JSON}")"
    GPU_QM_SLOT="${GPU_SLOT#0000:}"
  else
    GPU_BDF="" GPU_SLOT="" GPU_QM_SLOT=""
  fi
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
  SELECTED_GPU_SLOTS=("${GPU_SLOT}")
  SELECTION_SET_JSON="$(jq -cn --argjson gpu "${SELECTED_GPU_JSON}" '{mode:"single",gpus:[$gpu],slots:[$gpu.slot],display_bdfs:$gpu.display_bdfs,functions:$gpu.functions}')"
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

gpu.load_host_state_selection() {
  local file="$1" format="" bdf="" state_binding=""
  [[ -r "${file}" ]] || return 1
  gpu.state_is_json "${file}" || return 1
  format="$(jq -r '.format // 0' "${file}" 2>/dev/null)"
  if ((format >= 4)); then
    jq -e '
      (.gpu_selections | type == "array" and length > 0)
      and (.gpu_slots | type == "array" and length > 0)
      and (.gpu_function_records | type == "array" and length > 0)
      and ((.gpu_slots | length) == (.gpu_slots | unique | length))
      and ((.gpu_selections | length) == (.gpu_slots | length))
      and ((.gpu_slots | unique | sort) == ([.gpu_selections[].slot] | unique | sort))
      and ((.gpu_bdfs | unique | sort) == ([.gpu_selections[].selected_bdf] | unique | sort))
      and ((.gpu_functions | unique | sort) == (.gpu_function_records | map(.bdf) | unique | sort))
      and ((.gpu_function_records | map(.bdf) | unique | sort) == ([.gpu_selections[].functions[].bdf] | unique | sort))
      and all(.gpu_selections[];
        (. as $gpu
          | .selected_bdf as $selected
          | (.display_bdfs | index($selected)) != null
          and ($selected | startswith($gpu.slot + "."))
          and all($gpu.functions[]; .bdf | startswith($gpu.slot + "."))
          and ($gpu.functions | any(.bdf == $selected and (.class | startswith("0x03"))))))
      and ((.blacklist_vendors // []) | difference(["amd", "nvidia"]) | length == 0)
      and ((.exact_bind_only_vendors // []) | difference(["amd", "nvidia"]) | length == 0)
      and (. as $state
        | [($state.blacklist_vendors // [])[]
            | . as $vendor
            | select(($state.exact_bind_only_vendors // []) | index($vendor))]
        | length == 0)
    ' "${file}" >/dev/null 2>&1 || return 1
    SELECTION_SET_JSON="$(jq -c '{mode:(if (.gpu_selections|length)==1 then "single" else "host-set" end),gpus:.gpu_selections,slots:.gpu_slots,display_bdfs:([.gpu_selections[].display_bdfs[]]|unique|sort),functions:.gpu_function_records}' "${file}")"
    jq -e '.gpus | length > 0' <<< "${SELECTION_SET_JSON}" >/dev/null || return 1
    SELECTED_GPU_JSON="$(jq -c 'if (.gpus|length)==1 then .gpus[0] else null end' <<< "${SELECTION_SET_JSON}")"
    BLACKLIST_POLICY_JSON="$(jq -c '{requested:((((.blacklist_vendors // [])|length)>0) or (((.exact_bind_only_vendors // [])|length)>0)),input_mode:"state",requested_vendors:((.blacklist_vendors // []) + (.exact_bind_only_vendors // []) | unique | sort),effective_vendors:(.blacklist_vendors // []),exact_bind_only_vendors:(.exact_bind_only_vendors // []),requested_bdfs:(.gpu_bdfs // []),affected_bdfs:(.gpu_bdfs // []),affected_slots:(.gpu_slots // []),affected_function_bdfs:(.gpu_functions // [])}' "${file}")"
    state_binding="$(jq -r '.binding_strategy // empty' "${file}")"
    [[ -z "${state_binding}" ]] || BINDING_EFFECTIVE="${state_binding}"
    GPU_FUNCTIONS=()
    SELECTED_GPU_SLOTS=()
    while IFS= read -r bdf; do [[ -n "${bdf}" ]] && GPU_FUNCTIONS+=("${bdf}"); done < <(jq -r '.functions[].bdf' <<< "${SELECTION_SET_JSON}")
    while IFS= read -r bdf; do [[ -n "${bdf}" ]] && SELECTED_GPU_SLOTS+=("${bdf}"); done < <(jq -r '.slots[]' <<< "${SELECTION_SET_JSON}")
    if [[ "${SELECTED_GPU_JSON}" != null ]]; then
      GPU_BDF="$(jq -r '.selected_bdf' <<< "${SELECTED_GPU_JSON}")"
      GPU_SLOT="$(jq -r '.slot' <<< "${SELECTED_GPU_JSON}")"
      GPU_QM_SLOT="${GPU_SLOT#0000:}"
    else
      GPU_BDF="" GPU_SLOT="" GPU_QM_SLOT=""
    fi
    return 0
  fi
  gpu.load_state_selection "${file}"
  SELECTION_SET_JSON="$(jq -cn --argjson gpu "${SELECTED_GPU_JSON}" '{mode:"single",gpus:[$gpu],slots:[$gpu.slot],display_bdfs:$gpu.display_bdfs,functions:$gpu.functions}')"
  SELECTED_GPU_SLOTS=("${GPU_SLOT}")
  state_binding="$(gpu.state_value binding_strategy "${file}" || true)"
  [[ -z "${state_binding}" ]] || BINDING_EFFECTIVE="${state_binding}"
}

gpu.discover_or_restore_host_functions() {
  local state_file="$1"
  gpu.capture_inventory
  gpu.load_host_state_selection "${state_file}" || gpu.die "${GPU_EXIT_PREFLIGHT}" \
    "managed host state lacks a complete recoverable GPU selection"
}
