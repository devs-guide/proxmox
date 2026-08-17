#!/usr/bin/env bash
# GPU action dispatcher and Ansible mutation launcher.
set -euo pipefail

GPU_COMPONENT="cli.gpu.apply"
CLI_ROOT="${PROXMOX_GPU_CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=cli/gpu/common.sh
source "${CLI_ROOT}/gpu/common.sh"
export PROXMOX_GPU_INSPECT_LIBRARY=1
# shellcheck source=cli/gpu/inspect.sh
source "${CLI_ROOT}/gpu/inspect.sh"

gpu.request_json() {
  local functions='[]' bootloader="" legacy_host='{}' legacy_vm='{}'
  functions="$(gpu.render_selected_json)"
  bootloader="$(gpu.detect_bootloader)"

  if [[ -r "${STATE_ROOT}/host.state" ]] && ! gpu.state_is_json "${STATE_ROOT}/host.state"; then
    legacy_host="$(jq -cn --arg gpu_slot "$(gpu.state_value gpu_slot "${STATE_ROOT}/host.state" || true)" --arg bootloader "$(gpu.state_value bootloader "${STATE_ROOT}/host.state" || true)" --arg blacklist "$(gpu.state_value blacklist_host_drivers "${STATE_ROOT}/host.state" || true)" --arg pve_major "$(gpu.state_value pve_major "${STATE_ROOT}/host.state" || true)" '{gpu_slot:$gpu_slot,bootloader:$bootloader,pve_major:$pve_major,blacklist_host_drivers:($blacklist=="1")}')"
  fi
  if [[ -n "${VM_ID}" && -r "${STATE_ROOT}/vm-${VM_ID}.state" ]] && ! gpu.state_is_json "${STATE_ROOT}/vm-${VM_ID}.state"; then
    legacy_vm="$(jq -cn --arg vmid "$(gpu.state_value vm "${STATE_ROOT}/vm-${VM_ID}.state" || true)" --arg gpu_slot "$(gpu.state_value gpu_slot "${STATE_ROOT}/vm-${VM_ID}.state" || true)" --arg hostpci "$(gpu.state_value hostpci_index "${STATE_ROOT}/vm-${VM_ID}.state" || true)" --arg vga "$(gpu.state_value original_vga "${STATE_ROOT}/vm-${VM_ID}.state" || true)" '{vmid:(if $vmid=="" then null else ($vmid|tonumber) end),gpu_slot:$gpu_slot,hostpci_index:(if $hostpci=="" then null else ($hostpci|tonumber) end),original_vga:$vga}')"
  fi

  jq -cn \
    --arg action "${ACTION}" \
    --arg release "${EFFECTIVE_RELEASE}" \
    --arg pve_version "${PVE_VERSION}" \
    --arg codename "${DEBIAN_CODENAME}" \
    --arg vmid "${VM_ID}" \
    --arg gpu_slot "${GPU_SLOT}" \
    --arg gpu_bdf "${GPU_BDF}" \
    --arg gpu_qm_slot "${GPU_QM_SLOT}" \
    --arg profile "${PROFILE}" \
    --arg hostpci "${SELECTED_HOSTPCI_INDEX:-${HOSTPCI_INDEX}}" \
    --arg binding "${BINDING_EFFECTIVE}" \
    --arg bootloader "${bootloader}" \
    --arg sysfs_root "${SYSFS_ROOT}" \
    --arg proc_root "${PROC_ROOT}" \
    --arg etc_root "${ETC_ROOT}" \
    --arg pve_root "${PVE_ROOT}" \
    --arg state_root "${STATE_ROOT}" \
    --argjson platform "${PLATFORM_JSON}" \
    --argjson adapter "${ADAPTER_JSON}" \
    --argjson inventory "${INVENTORY_JSON}" \
    --argjson selection "${SELECTED_GPU_JSON}" \
    --argjson functions "${functions}" \
    --argjson dry_run "$([[ ${DRY_RUN} -eq 1 ]] && printf true || printf false)" \
    --argjson start_vm "$([[ ${START_VM} -eq 1 ]] && printf true || printf false)" \
    --argjson reboot_host "$([[ ${REBOOT_HOST} -eq 1 ]] && printf true || printf false)" \
    --argjson blacklist "$([[ ${BLACKLIST_HOST_DRIVERS} -eq 1 ]] && printf true || printf false)" \
    --argjson primary "$([[ ${PRIMARY_GPU} -eq 1 ]] && printf true || printf false)" \
    --argjson disable_onboot "$([[ ${DISABLE_ONBOOT} -eq 1 ]] && printf true || printf false)" \
    --argjson iommu_pt "$([[ ${IOMMU_PT} -eq 1 ]] && printf true || printf false)" \
    --argjson display_loss "$([[ ${ALLOW_HOST_DISPLAY_LOSS} -eq 1 ]] && printf true || printf false)" \
    --argjson console_loss "$([[ ${ALLOW_GUEST_CONSOLE_LOSS} -eq 1 ]] && printf true || printf false)" \
    --argjson iommu_ready "$([[ ${IOMMU_READY:-0} -eq 1 ]] && printf true || printf false)" \
    --argjson legacy_host "${legacy_host}" \
    --argjson legacy_vm "${legacy_vm}" \
    '{gpu_request:{schema_version:3,action:$action,
      platform:$platform,adapter:$adapter,inventory:$inventory,selection:$selection,
      release:$release,pve_version:$pve_version,debian_codename:$codename,
      vmid:(if $vmid=="" then null else ($vmid|tonumber) end),
      gpu_slot:$gpu_slot,gpu_bdf:$gpu_bdf,gpu_qm_slot:$gpu_qm_slot,functions:$functions,
      profile:$profile,
      hostpci_index:(if $hostpci=="auto" or $hostpci=="" then null else ($hostpci|tonumber) end),
      requested_features:{binding:$binding,blacklist_host_drivers:$blacklist,
        primary_gpu:$primary,disable_onboot:$disable_onboot,iommu_pt:$iommu_pt,
        start_vm:$start_vm,reboot_host:$reboot_host},
      approvals:{allow_host_display_loss:$display_loss,allow_guest_console_loss:$console_loss},
      dry_run:$dry_run,detected:{bootloader:$bootloader,iommu_ready:$iommu_ready},
      roots:{sysfs:$sysfs_root,proc:$proc_root,etc:$etc_root,pve:$pve_root,state:$state_root},
      legacy:{host:$legacy_host,vm:$legacy_vm}}}'
}

gpu.prepare_state_inputs() {
  local host_state="${STATE_ROOT}/host.state" vm_state=""
  case "${ACTION}" in
    detach)
      [[ -n "${VM_ID}" ]] || gpu.die "${GPU_EXIT_USAGE}" "--vm is required for detach"
      vm_state="${STATE_ROOT}/vm-${VM_ID}.state"
      [[ -r "${vm_state}" ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "no feature-owned attachment state exists for VM ${VM_ID}"
      if [[ -z "${GPU_INPUT}" ]]; then GPU_INPUT="$(gpu.state_value gpu_bdf "${vm_state}" || true)"; fi
      ;;
    unprepare)
      [[ -r "${host_state}" ]] || gpu.die "${GPU_EXIT_PREFLIGHT}" "no feature-owned host state exists"
      if [[ -z "${GPU_INPUT}" ]]; then GPU_INPUT="$(gpu.state_value gpu_bdf "${host_state}" || true)"; fi
      ;;
  esac
}

gpu.apply_main() {
  local request_file="" result_file="" playbook="" ansible_rc=0
  gpu.parse_args "$@"

  if ! gpu.is_mutating_action "${ACTION}"; then
    export PROXMOX_GPU_INSPECT_LIBRARY=0
    exec bash "${CLI_ROOT}/gpu/inspect.sh" "$@"
  fi

  gpu.require_root
  gpu.require_commands jq sed grep sort readlink basename qm pveversion flock ansible-playbook
  gpu.detect_release
  gpu.prepare_state_inputs

  case "${ACTION}" in
    prepare)
      gpu.preflight_selected 1
      if ((IOMMU_READY == 0)) && [[ "$(awk -F: '/vendor_id/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "${PROC_ROOT}/cpuinfo" 2>/dev/null)" == AuthenticAMD ]]; then
        gpu.die "${GPU_EXIT_PREFLIGHT}" "AMD host has no IOMMU groups; enable AMD-Vi/IOMMU in firmware before prepare"
      fi
      ;;
    attach)
      gpu.preflight_selected 0
      ;;
    detach)
      gpu.discover_or_restore_functions "${STATE_ROOT}/vm-${VM_ID}.state"
      gpu.validate_vm_stopped_only
      ;;
    unprepare)
      gpu.discover_or_restore_functions "${STATE_ROOT}/host.state"
      ;;
  esac

  ((DRY_RUN == 1 || YES == 1)) || gpu.die "${GPU_EXIT_PREFLIGHT}" "${ACTION} requires --yes; use --dry-run to preview"
  playbook="$(gpu.playbook_for_release)"
  [[ -r "${playbook}" ]] || gpu.die "${GPU_EXIT_DEPENDENCY}" "release playbook is missing: ${playbook}"
  if ((DRY_RUN == 0)); then
    mkdir -p "${STATE_ROOT}"
  else
    LOCK_FILE="${TMPDIR:-/tmp}/proxmox-vm-gpu.dry-run.lock"
  fi
  request_file="$(mktemp "${TMPDIR:-/tmp}/proxmox-gpu-request.json.XXXXXX")"
  result_file="$(mktemp "${TMPDIR:-/tmp}/proxmox-gpu-result.json.XXXXXX")"
  trap 'rm -f "${request_file:-}" "${result_file:-}"' EXIT
  gpu.request_json > "${request_file}"
  chmod 0600 "${request_file}" "${result_file}"

  exec 9>"${LOCK_FILE}"
  flock -n 9 || gpu.die "${GPU_EXIT_MUTATION}" "another GPU passthrough mutation is active"
  set +e
  ansible-playbook -i localhost, -c local -e "@${request_file}" -e "gpu_result_path=${result_file}" "${playbook}" >&2
  ansible_rc=$?
  set -e
  if ((ansible_rc != 0)); then
    if [[ -s "${result_file}" ]]; then cat "${result_file}"; fi
    gpu.die "${GPU_EXIT_MUTATION}" "${ACTION} playbook failed (ansible rc=${ansible_rc})"
  fi

  [[ -s "${result_file}" ]] || gpu.die "${GPU_EXIT_MUTATION}" "playbook did not produce a result document"
  if [[ "${OUTPUT}" == json ]]; then
    cat "${result_file}"
  else
    jq -r '"[cli.gpu.apply] " + (.result.message // .result.state)' "${result_file}" >&2
  fi
  if ((REBOOT_HOST == 1 && DRY_RUN == 0)); then
    gpu.log "rebooting after successful ${ACTION}"
    reboot
  fi
}

gpu.apply_main "$@"
