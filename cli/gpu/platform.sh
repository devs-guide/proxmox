#!/usr/bin/env bash
# Authoritative Proxmox platform detection and GPU adapter selection.

PLATFORM_JSON='{}'
ADAPTER_JSON='{}'
ADAPTER_PLAYBOOK_REL=""
DETECTED_BOOTLOADER=""

gpu.platform_os_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "${ETC_ROOT}/os-release" 2>/dev/null \
    | tr -d '"' \
    | head -n1
}

gpu.platform_detect_bootloader() {
  local detected=""

  if [[ -n "${BOOTLOADER_OVERRIDE}" ]]; then
    [[ "${TEST_MODE}" == 1 ]] || gpu.die "${GPU_EXIT_ENVIRONMENT}" \
      "PROXMOX_GPU_BOOTLOADER is test-only; live boot tooling must be detected"
    detected="${BOOTLOADER_OVERRIDE}"
  elif [[ -r "${ETC_ROOT}/kernel/cmdline" ]] && gpu.command_exists proxmox-boot-tool; then
    detected="proxmox-boot-tool"
  elif [[ -r "${ETC_ROOT}/kernel/cmdline" ]] && gpu.command_exists pve-efiboot-tool; then
    detected="pve-efiboot-tool"
  elif gpu.command_exists update-grub \
    && { [[ -r "${ETC_ROOT}/default/grub" ]] || [[ -d "${ETC_ROOT}/default/grub.d" ]]; }; then
    detected="grub"
  else
    gpu.die "${GPU_EXIT_ENVIRONMENT}" \
      "unable to prove a supported bootloader contract from live node capabilities"
  fi

  case "${detected}" in
    grub|proxmox-boot-tool|pve-efiboot-tool) ;;
    *) gpu.die "${GPU_EXIT_ENVIRONMENT}" "unsupported bootloader contract: ${detected}" ;;
  esac
  gpu.command_exists "${detected}" || gpu.die "${GPU_EXIT_DEPENDENCY}" \
    "detected bootloader command is missing: ${detected}"
  DETECTED_BOOTLOADER="${detected}"
}

gpu.platform_detect() {
  local debian_id="" debian_version="" kernel_version=""
  local adapter_id="" adapter_lane="" default_binding=""
  local automatic_handoff=false probe_vfio_virqfd=false legacy_boot_tool_fallback=false
  local supported_bindings='[]'

  if [[ "${TEST_MODE}" != 1 ]]; then
    gpu.command_exists pveversion || gpu.die "${GPU_EXIT_ENVIRONMENT}" "pveversion is missing"
    [[ -d "${PVE_ROOT}" ]] || gpu.die "${GPU_EXIT_ENVIRONMENT}" "${PVE_ROOT} is missing"
  fi
  [[ -r "${ETC_ROOT}/os-release" ]] || gpu.die "${GPU_EXIT_ENVIRONMENT}" \
    "${ETC_ROOT}/os-release is missing"

  PVE_VERSION="$(pveversion 2>/dev/null \
    | sed -n 's|.*pve-manager/\([^/[:space:]]*\).*|\1|p' \
    | head -n1)"
  [[ "${PVE_VERSION}" =~ ^[0-9]+\.[0-9]+([.~-][0-9A-Za-z.+:~_-]+)*$ ]] \
    || gpu.die "${GPU_EXIT_ENVIRONMENT}" \
      "unable to detect a complete Proxmox VE version"
  PVE_MAJOR="${PVE_VERSION%%.*}"
  DEBIAN_CODENAME="$(gpu.platform_os_value VERSION_CODENAME)"
  debian_id="$(gpu.platform_os_value ID)"
  debian_version="$(gpu.platform_os_value VERSION_ID)"
  kernel_version="$(uname -r 2>/dev/null || true)"

  [[ "${debian_id}" == debian ]] || gpu.die "${GPU_EXIT_ENVIRONMENT}" \
    "unsupported operating-system identity: ${debian_id:-unknown}"

  gpu.platform_detect_bootloader

  case "${PVE_MAJOR}:${DEBIAN_CODENAME}" in
    6:buster)
      [[ "${debian_version}" == 10 || "${debian_version}" == 10.* ]] \
        || gpu.die "${GPU_EXIT_ENVIRONMENT}" \
          "PVE 6 adapter requires detected Debian 10/Buster"
      adapter_id="pve6-buster"
      adapter_lane="6.4"
      ADAPTER_PLAYBOOK_REL="release/6.4/gpu.yml"
      default_binding="early"
      supported_bindings='["early"]'
      probe_vfio_virqfd=true
      legacy_boot_tool_fallback=true
      ;;
    9:trixie)
      [[ "${debian_version}" == 13 || "${debian_version}" == 13.* ]] \
        || gpu.die "${GPU_EXIT_ENVIRONMENT}" \
          "PVE 9 adapter requires detected Debian 13/Trixie"
      adapter_id="pve9-trixie"
      adapter_lane="9.1"
      ADAPTER_PLAYBOOK_REL="release/9.1/gpu.yml"
      default_binding="automatic"
      supported_bindings='["automatic","early"]'
      automatic_handoff=true
      ;;
    *)
      gpu.die "${GPU_EXIT_ENVIRONMENT}" \
        "unsupported or mismatched live platform: pve=${PVE_VERSION}, codename=${DEBIAN_CODENAME:-unknown}"
      ;;
  esac

  if [[ -n "${REQUESTED_RELEASE}" && "${REQUESTED_RELEASE}" != auto \
    && "${REQUESTED_RELEASE}" != "${adapter_lane}" ]]; then
    gpu.die "${GPU_EXIT_ENVIRONMENT}" \
      "release assertion ${REQUESTED_RELEASE} does not match detected adapter ${adapter_lane}"
  fi

  EFFECTIVE_RELEASE="${adapter_lane}"
  if [[ "${BINDING_REQUESTED}" == release ]]; then
    BINDING_EFFECTIVE="${default_binding}"
  else
    BINDING_EFFECTIVE="${BINDING_REQUESTED}"
  fi
  jq -e --arg binding "${BINDING_EFFECTIVE}" \
    'index($binding) != null' <<< "${supported_bindings}" >/dev/null \
    || gpu.die "${GPU_EXIT_ENVIRONMENT}" \
      "binding ${BINDING_EFFECTIVE} is not supported by detected adapter ${adapter_lane}"

  PLATFORM_JSON="$(jq -cn \
    --arg pve_version "${PVE_VERSION}" \
    --arg pve_major "${PVE_MAJOR}" \
    --arg debian_id "${debian_id}" \
    --arg debian_version "${debian_version}" \
    --arg debian_codename "${DEBIAN_CODENAME}" \
    --arg kernel "${kernel_version}" \
    --arg bootloader "${DETECTED_BOOTLOADER}" \
    '{schema_version:1,pve:{version:$pve_version,major:$pve_major},debian:{id:$debian_id,version:$debian_version,codename:$debian_codename},kernel:$kernel,bootloader:$bootloader}')"
  ADAPTER_JSON="$(jq -cn \
    --arg id "${adapter_id}" \
    --arg lane "${adapter_lane}" \
    --arg playbook "${ADAPTER_PLAYBOOK_REL}" \
    --arg default_binding "${default_binding}" \
    --argjson supported_bindings "${supported_bindings}" \
    --argjson automatic_handoff "${automatic_handoff}" \
    --argjson probe_vfio_virqfd "${probe_vfio_virqfd}" \
    --argjson legacy_boot_tool_fallback "${legacy_boot_tool_fallback}" \
    '{schema_version:1,id:$id,lane:$lane,playbook:$playbook,default_binding:$default_binding,supported_bindings:$supported_bindings,automatic_handoff:$automatic_handoff,probe_vfio_virqfd:$probe_vfio_virqfd,legacy_boot_tool_fallback:$legacy_boot_tool_fallback}')"
}

gpu.detect_release() {
  gpu.platform_detect
}

gpu.detect_bootloader() {
  [[ -n "${DETECTED_BOOTLOADER}" ]] || gpu.platform_detect_bootloader
  printf '%s\n' "${DETECTED_BOOTLOADER}"
}

gpu.playbook_for_release() {
  [[ "${ADAPTER_PLAYBOOK_REL}" =~ ^release/(6\.4|9\.1)/gpu\.yml$ ]] \
    || gpu.die "${GPU_EXIT_ENVIRONMENT}" \
      "detected adapter returned an unsafe playbook path"
  printf '%s/%s\n' "${PLAYBOOK_ROOT}" "${ADAPTER_PLAYBOOK_REL}"
}
