#!/usr/bin/env bash
# GPU driver and hwmon temperature inventory with bounded runtime resume.

TEMPERATURE_COMPONENT="${TEMPERATURE_COMPONENT:-cli.temperature.gpu}"
TEMPERATURE_EXIT_USAGE=2
TEMPERATURE_EXIT_ENVIRONMENT=3
TEMPERATURE_EXIT_GATE=4
TEMPERATURE_SYSFS_ROOT="${PROXMOX_TEMPERATURE_SYSFS_ROOT:-${PROXMOX_GPU_SYSFS_ROOT:-/sys}}"
TEMPERATURE_VENDOR="amd"
TEMPERATURE_REQUIRE_DRIVER=""
TEMPERATURE_REQUIRE_READABLE=0
TEMPERATURE_REJECT_BOOT_VGA=0
TEMPERATURE_OUTPUT="human"
TEMPERATURE_SAMPLES="${PROXMOX_TEMPERATURE_SAMPLES:-3}"
TEMPERATURE_INTERVAL="${PROXMOX_TEMPERATURE_SAMPLE_INTERVAL:-1}"
TEMPERATURE_RUNTIME_WAKE_SETTLE="${PROXMOX_TEMPERATURE_RUNTIME_WAKE_SETTLE:-1}"
TEMPERATURE_BDFS_JSON='[]'
TEMPERATURE_GPU_JSON='{"schema_version":2,"component":"gpu","devices":[],"gate":{"passed":true,"failures":[]},"result":{"state":"ok"}}'
TEMPERATURE_RESTORE_PATH=""
TEMPERATURE_RESTORE_VALUE=""

temperature.gpu.error() {
  printf '[%s][error] %s\n' "${TEMPERATURE_COMPONENT}" "$*" >&2
}

temperature.gpu.die() {
  local code="$1"
  shift
  temperature.gpu.error "$*"
  return "${code}"
}

temperature.gpu.require_command() {
  command -v "$1" >/dev/null 2>&1 \
    || temperature.gpu.die "${TEMPERATURE_EXIT_ENVIRONMENT}" "missing required command: $1"
}

temperature.gpu.normalize_bdf() {
  local value=""
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "${value}" =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && value="0000:${value}"
  [[ "${value}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] \
    || temperature.gpu.die "${TEMPERATURE_EXIT_USAGE}" "invalid PCI BDF: $1"
  printf '%s\n' "${value}"
}

temperature.gpu.driver() {
  local link="${TEMPERATURE_SYSFS_ROOT}/bus/pci/devices/$1/driver"
  if [[ -L "${link}" ]]; then
    basename "$(readlink "${link}")"
  else
    printf 'unbound\n'
  fi
}

temperature.gpu.vendor_id() {
  case "$1" in
    amd) printf '0x1002\n' ;;
    all) printf '\n' ;;
    *) temperature.gpu.die "${TEMPERATURE_EXIT_USAGE}" "--vendor supports amd or all" ;;
  esac
}

temperature.gpu.model() {
  local bdf="$1" model=""
  if command -v lspci >/dev/null 2>&1; then
    model="$(lspci -Dnnk -s "${bdf}" 2>/dev/null | sed -n '1s/^[^ ]* //p' || true)"
  fi
  printf '%s\n' "${model}"
}

temperature.gpu.power_restore() {
  [[ -n "${TEMPERATURE_RESTORE_PATH}" ]] || return 0
  printf '%s\n' "${TEMPERATURE_RESTORE_VALUE}" > "${TEMPERATURE_RESTORE_PATH}"
}

temperature.gpu.sample_inputs() {
  local device_path="$1" phase="$2"
  local hwmon_path="" hwmon_name="" input_path="" input_name="" label_path="" label=""
  local raw="" celsius="" read_error="" samples='[]' sensors='[]' attempts='[]' sensor='null' attempt='null'
  local sample_index=0
  local -a hwmon_paths=() input_paths=()

  shopt -s nullglob
  hwmon_paths=("${device_path}/hwmon/"hwmon*)
  for hwmon_path in "${hwmon_paths[@]}"; do
    [[ -d "${hwmon_path}" || -L "${hwmon_path}" ]] || continue
    hwmon_name="$([[ -r "${hwmon_path}/name" ]] && tr -d '\n' < "${hwmon_path}/name" || basename "${hwmon_path}")"
    input_paths=("${hwmon_path}/"temp*_input)
    for input_path in "${input_paths[@]}"; do
      input_name="$(basename "${input_path}")"
      label_path="${input_path%_input}_label"
      label="$([[ -r "${label_path}" ]] && tr -d '\n' < "${label_path}" || true)"
      [[ -n "${label}" ]] || label="${input_name%_input}"
      samples='[]'
      read_error=""
      for ((sample_index = 0; sample_index < TEMPERATURE_SAMPLES; sample_index++)); do
        if raw="$(tr -d '[:space:]' < "${input_path}" 2>&1)"; then
          if [[ "${raw}" =~ ^-?[0-9]+$ ]]; then
            celsius="$(awk -v raw="${raw}" 'BEGIN { printf "%.3f", raw / 1000 }')"
            samples="$(jq -c --argjson value "${celsius}" '. + [$value]' <<< "${samples}")"
          else
            read_error="non-numeric value: ${raw:-empty}"
          fi
        else
          read_error="${raw:-read failed}"
        fi
        if ((sample_index + 1 < TEMPERATURE_SAMPLES)) && [[ "${TEMPERATURE_INTERVAL}" != 0 ]]; then
          sleep "${TEMPERATURE_INTERVAL}"
        fi
      done
      attempt="$(jq -cn \
        --arg hwmon "${hwmon_name}" \
        --arg label "${label}" \
        --arg source "${input_path#${TEMPERATURE_SYSFS_ROOT}}" \
        --arg phase "${phase}" \
        --arg error "${read_error}" \
        --argjson readable "$([[ "$(jq -r 'length' <<< "${samples}")" -gt 0 ]] && printf true || printf false)" \
        '{hwmon:$hwmon,label:$label,source:$source,phase:$phase,readable:$readable,
          error:(if $error=="" then null else $error end)}')"
      attempts="$(jq -c --argjson attempt "${attempt}" '. + [$attempt]' <<< "${attempts}")"
      [[ "$(jq -r 'length' <<< "${samples}")" -gt 0 ]] || continue
      sensor="$(jq -cn \
        --arg hwmon "${hwmon_name}" \
        --arg label "${label}" \
        --arg source "${input_path#${TEMPERATURE_SYSFS_ROOT}}" \
        --argjson samples "${samples}" \
        '{hwmon:$hwmon,label:$label,source:$source,unit:"celsius",samples:$samples,
          minimum:($samples|min),maximum:($samples|max),average:($samples|add/length)}')"
      sensors="$(jq -c --argjson sensor "${sensor}" '. + [$sensor]' <<< "${sensors}")"
    done
  done
  shopt -u nullglob
  jq -cn --argjson sensors "${sensors}" --argjson attempts "${attempts}" \
    '{sensors:$sensors,attempts:$attempts}'
}

temperature.gpu.capture_device() {
  local device_path="$1" driver="$2"
  local initial='{}' after_wake='{}' sensors='[]' attempts='[]'
  local runtime_before="unknown" runtime_after="unknown" control_before="unknown" control_after="unknown"
  local power_path="${device_path}/power/control" runtime_path="${device_path}/power/runtime_status"
  local wake_attempted=false wake_succeeded=false restored=true wake_error=""

  [[ -r "${runtime_path}" ]] && runtime_before="$(tr -d '[:space:]' < "${runtime_path}")"
  [[ -r "${power_path}" ]] && control_before="$(tr -d '[:space:]' < "${power_path}")"
  runtime_after="${runtime_before}"
  control_after="${control_before}"
  initial="$(temperature.gpu.sample_inputs "${device_path}" initial)"
  sensors="$(jq -c '.sensors' <<< "${initial}")"
  attempts="$(jq -c '.attempts' <<< "${initial}")"

  if [[ "$(jq -r 'length' <<< "${sensors}")" -eq 0 \
    && "${TEMPERATURE_REQUIRE_READABLE}" -eq 1 \
    && "${driver}" == amdgpu \
    && ( "${runtime_before}" == suspended || "${runtime_before}" == suspending ) ]]; then
    wake_attempted=true
    if [[ ! -w "${power_path}" || "${control_before}" == unknown ]]; then
      wake_error="runtime power control is not writable"
    else
      TEMPERATURE_RESTORE_PATH="${power_path}"
      TEMPERATURE_RESTORE_VALUE="${control_before}"
      trap 'temperature.gpu.power_restore >/dev/null 2>&1 || true' EXIT
      trap 'temperature.gpu.power_restore >/dev/null 2>&1 || true; exit 130' INT
      trap 'temperature.gpu.power_restore >/dev/null 2>&1 || true; exit 143' TERM
      if printf 'on\n' > "${power_path}"; then
        wake_succeeded=true
        [[ "${TEMPERATURE_RUNTIME_WAKE_SETTLE}" == 0 ]] || sleep "${TEMPERATURE_RUNTIME_WAKE_SETTLE}"
        [[ -r "${runtime_path}" ]] && runtime_after="$(tr -d '[:space:]' < "${runtime_path}")"
        after_wake="$(temperature.gpu.sample_inputs "${device_path}" after_runtime_wake)"
        sensors="$(jq -c '.sensors' <<< "${after_wake}")"
        attempts="$(jq -c --argjson more "$(jq -c '.attempts' <<< "${after_wake}")" '. + $more' <<< "${attempts}")"
      else
        wake_error="failed to write on to runtime power control"
      fi
      if temperature.gpu.power_restore; then
        TEMPERATURE_RESTORE_PATH=""
        TEMPERATURE_RESTORE_VALUE=""
        trap - EXIT INT TERM
        control_after="$([[ -r "${power_path}" ]] && tr -d '[:space:]' < "${power_path}" || printf unknown)"
      else
        restored=false
        wake_error="${wake_error:+${wake_error}; }failed to restore runtime power control"
      fi
    fi
  fi

  jq -cn \
    --argjson sensors "${sensors}" \
    --argjson attempts "${attempts}" \
    --arg runtime_status_before "${runtime_before}" \
    --arg runtime_status_after "${runtime_after}" \
    --arg control_before "${control_before}" \
    --arg control_after "${control_after}" \
    --argjson wake_attempted "${wake_attempted}" \
    --argjson wake_succeeded "${wake_succeeded}" \
    --argjson restored "${restored}" \
    --arg wake_error "${wake_error}" \
    '{sensors:$sensors,attempts:$attempts,power:{runtime_status_before:$runtime_status_before,
      runtime_status_after:$runtime_status_after,control_before:$control_before,control_after:$control_after,
      wake_attempted:$wake_attempted,wake_succeeded:$wake_succeeded,restored:$restored,
      error:(if $wake_error=="" then null else $wake_error end)}}'
}

temperature.gpu.capture() {
  local expected_vendor="" device_path="" bdf="" class="" vendor_id="" device_id=""
  local subsystem_vendor="" subsystem_device="" driver="" boot_vga="" model=""
  local devices='[]' failures='[]' found_bdfs='[]' sensors='[]'
  local attempts='[]' power='{}' acquisition='{}' sensor_count=0
  local selected_bdf="" captured_at="" status="ok"
  local -a device_paths=()

  temperature.gpu.require_command jq || return "$?"
  temperature.gpu.require_command awk || return "$?"
  temperature.gpu.require_command readlink || return "$?"
  temperature.gpu.require_command basename || return "$?"
  [[ -d "${TEMPERATURE_SYSFS_ROOT}/bus/pci/devices" ]] \
    || temperature.gpu.die "${TEMPERATURE_EXIT_ENVIRONMENT}" \
      "PCI sysfs tree is unavailable: ${TEMPERATURE_SYSFS_ROOT}/bus/pci/devices" || return "$?"

  expected_vendor="$(temperature.gpu.vendor_id "${TEMPERATURE_VENDOR}")" || return "$?"
  captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')"
  shopt -s nullglob
  device_paths=("${TEMPERATURE_SYSFS_ROOT}/bus/pci/devices/"*)
  for device_path in "${device_paths[@]}"; do
    [[ -r "${device_path}/class" && -r "${device_path}/vendor" ]] || continue
    class="$(tr -d '\n' < "${device_path}/class")"
    [[ "${class}" == 0x03* ]] || continue
    vendor_id="$(tr -d '\n' < "${device_path}/vendor")"
    [[ -z "${expected_vendor}" || "${vendor_id}" == "${expected_vendor}" ]] || continue
    bdf="$(basename "${device_path}")"
    if [[ "$(jq -r 'length' <<< "${TEMPERATURE_BDFS_JSON}")" -gt 0 ]]; then
      jq -e --arg bdf "${bdf}" 'index($bdf) != null' <<< "${TEMPERATURE_BDFS_JSON}" >/dev/null \
        || continue
    fi

    found_bdfs="$(jq -c --arg bdf "${bdf}" '. + [$bdf]' <<< "${found_bdfs}")"
    device_id="$([[ -r "${device_path}/device" ]] && tr -d '\n' < "${device_path}/device" || true)"
    subsystem_vendor="$([[ -r "${device_path}/subsystem_vendor" ]] && tr -d '\n' < "${device_path}/subsystem_vendor" || true)"
    subsystem_device="$([[ -r "${device_path}/subsystem_device" ]] && tr -d '\n' < "${device_path}/subsystem_device" || true)"
    driver="$(temperature.gpu.driver "${bdf}")"
    boot_vga="$([[ -r "${device_path}/boot_vga" ]] && tr -d '\n' < "${device_path}/boot_vga" || printf 0)"
    model="$(temperature.gpu.model "${bdf}")"
    acquisition="$(temperature.gpu.capture_device "${device_path}" "${driver}")"
    sensors="$(jq -c '.sensors' <<< "${acquisition}")"
    attempts="$(jq -c '.attempts' <<< "${acquisition}")"
    power="$(jq -c '.power' <<< "${acquisition}")"
    sensor_count="$(jq -r 'length' <<< "${sensors}")"

    if [[ -n "${TEMPERATURE_REQUIRE_DRIVER}" && "${driver}" != "${TEMPERATURE_REQUIRE_DRIVER}" ]]; then
      failures="$(jq -c --arg value "${bdf}: expected driver ${TEMPERATURE_REQUIRE_DRIVER}, found ${driver}" '. + [$value]' <<< "${failures}")"
    fi
    if ((TEMPERATURE_REQUIRE_READABLE == 1 && sensor_count == 0)); then
      failures="$(jq -c --arg value "${bdf}: no readable hwmon temperature inputs" '. + [$value]' <<< "${failures}")"
    fi
    if [[ "$(jq -r '.wake_attempted' <<< "${power}")" == true \
      && "$(jq -r '.restored' <<< "${power}")" != true ]]; then
      failures="$(jq -c --arg value "${bdf}: runtime power policy restoration failed" '. + [$value]' <<< "${failures}")"
    fi
    if ((TEMPERATURE_REJECT_BOOT_VGA == 1)) && [[ "${boot_vga}" == 1 ]]; then
      failures="$(jq -c --arg value "${bdf}: boot_vga is not eligible for passthrough blacklisting" '. + [$value]' <<< "${failures}")"
    fi

    devices="$(jq -c \
      --arg bdf "${bdf}" \
      --arg class "${class}" \
      --arg vendor_id "${vendor_id}" \
      --arg device_id "${device_id}" \
      --arg subsystem_vendor_id "${subsystem_vendor}" \
      --arg subsystem_device_id "${subsystem_device}" \
      --arg model "${model}" \
      --arg driver "${driver}" \
      --arg boot_vga "${boot_vga}" \
      --argjson sensors "${sensors}" \
      --argjson attempts "${attempts}" \
      --argjson power "${power}" \
      '. + [{bdf:$bdf,class:$class,vendor_id:$vendor_id,device_id:$device_id,
        subsystem_vendor_id:(if $subsystem_vendor_id=="" then null else $subsystem_vendor_id end),
        subsystem_device_id:(if $subsystem_device_id=="" then null else $subsystem_device_id end),
        model:(if $model=="" then null else $model end),driver:$driver,
        boot_vga:($boot_vga=="1"),sensors:$sensors,
        acquisition:{readable:($sensors|length>0),sensor_count:($sensors|length),
          attempts:$attempts,power:$power}}]' <<< "${devices}")"
  done
  shopt -u nullglob

  if [[ "$(jq -r 'length' <<< "${TEMPERATURE_BDFS_JSON}")" -gt 0 ]]; then
    while IFS= read -r selected_bdf; do
      jq -e --arg bdf "${selected_bdf}" 'index($bdf) != null' <<< "${found_bdfs}" >/dev/null \
        || failures="$(jq -c --arg value "${selected_bdf}: selected GPU was not found" '. + [$value]' <<< "${failures}")"
    done < <(jq -r '.[]' <<< "${TEMPERATURE_BDFS_JSON}")
  elif [[ "$(jq -r 'length' <<< "${devices}")" -eq 0 ]]; then
    failures="$(jq -c --arg value "no ${TEMPERATURE_VENDOR} display GPUs were found" '. + [$value]' <<< "${failures}")"
  fi

  [[ "$(jq -r 'length' <<< "${failures}")" -eq 0 ]] || status="failed"
  TEMPERATURE_GPU_JSON="$(jq -cn \
    --arg captured_at "${captured_at}" \
    --arg vendor "${TEMPERATURE_VENDOR}" \
    --arg required_driver "${TEMPERATURE_REQUIRE_DRIVER}" \
    --argjson require_readable "$([[ ${TEMPERATURE_REQUIRE_READABLE} -eq 1 ]] && printf true || printf false)" \
    --argjson reject_boot_vga "$([[ ${TEMPERATURE_REJECT_BOOT_VGA} -eq 1 ]] && printf true || printf false)" \
    --argjson samples "${TEMPERATURE_SAMPLES}" \
    --arg interval "${TEMPERATURE_INTERVAL}" \
    --argjson devices "${devices}" \
    --argjson failures "${failures}" \
    --arg state "${status}" \
    '{schema_version:2,component:"gpu",captured_at:$captured_at,
      policy:{vendor:$vendor,required_driver:(if $required_driver=="" then null else $required_driver end),
        require_readable:$require_readable,reject_boot_vga:$reject_boot_vga,
        samples_per_sensor:$samples,sample_interval_seconds:($interval|tonumber),
        runtime_wake:"automatic-if-suspended"},
      devices:$devices,gate:{passed:($failures|length==0),failures:$failures},
      result:{state:$state}}')"

  [[ "${status}" == ok ]] || return "${TEMPERATURE_EXIT_GATE}"
}

temperature.gpu.parse_args() {
  local bdf="" bdfs='[]'
  while (($#)); do
    case "$1" in
      --vendor) [[ -n "${2-}" ]] || temperature.gpu.die "${TEMPERATURE_EXIT_USAGE}" "--vendor requires a value" || return "$?"; TEMPERATURE_VENDOR="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
      --require-driver) [[ -n "${2-}" ]] || temperature.gpu.die "${TEMPERATURE_EXIT_USAGE}" "--require-driver requires a value" || return "$?"; TEMPERATURE_REQUIRE_DRIVER="$2"; shift 2 ;;
      --require-readable) TEMPERATURE_REQUIRE_READABLE=1; shift ;;
      --reject-boot-vga) TEMPERATURE_REJECT_BOOT_VGA=1; shift ;;
      --gpu) [[ -n "${2-}" ]] || temperature.gpu.die "${TEMPERATURE_EXIT_USAGE}" "--gpu requires a value" || return "$?"; bdf="$(temperature.gpu.normalize_bdf "$2")" || return "$?"; bdfs="$(jq -c --arg bdf "${bdf}" '. + [$bdf] | unique' <<< "${bdfs}")"; shift 2 ;;
      --samples) [[ "${2-}" =~ ^([1-9]|1[0-9]|20)$ ]] || temperature.gpu.die "${TEMPERATURE_EXIT_USAGE}" "--samples must be 1..20" || return "$?"; TEMPERATURE_SAMPLES="$2"; shift 2 ;;
      --interval) [[ "${2-}" =~ ^([0-9]+([.][0-9]+)?)$ ]] || temperature.gpu.die "${TEMPERATURE_EXIT_USAGE}" "--interval must be a non-negative number" || return "$?"; TEMPERATURE_INTERVAL="$2"; shift 2 ;;
      --output) [[ "${2-}" == human || "${2-}" == json ]] || temperature.gpu.die "${TEMPERATURE_EXIT_USAGE}" "--output must be human or json" || return "$?"; TEMPERATURE_OUTPUT="$2"; shift 2 ;;
      -h|--help)
        cat <<'EOF'
Usage: setup/temperature/gpu.sh [options]
  --vendor amd|all
  --gpu PCI_BDF                 Repeat to select exact display functions
  --require-driver DRIVER
  --require-readable
  --reject-boot-vga
  --samples 1..20
  --interval SECONDS
  --output human|json
EOF
        return 10
        ;;
      *) temperature.gpu.die "${TEMPERATURE_EXIT_USAGE}" "unknown argument: $1" || return "$?" ;;
    esac
  done
  TEMPERATURE_BDFS_JSON="${bdfs}"
  temperature.gpu.vendor_id "${TEMPERATURE_VENDOR}" >/dev/null || return "$?"
}

temperature.gpu.main() {
  local rc=0
  temperature.gpu.parse_args "$@" || {
    rc=$?
    [[ "${rc}" -eq 10 ]] && return 0
    return "${rc}"
  }
  temperature.gpu.capture || rc=$?
  if [[ "${TEMPERATURE_OUTPUT}" == json ]]; then
    printf '%s\n' "${TEMPERATURE_GPU_JSON}"
  else
    jq -r '.devices[] |
      "\(.bdf) driver=\(.driver) boot_vga=\(.boot_vga) sensors=\(.acquisition.sensor_count) runtime=\(.acquisition.power.runtime_status_before) wake=\(.acquisition.power.wake_attempted)",
      (.sensors[]? | "  \(.label): current=\(.samples[-1])C min=\(.minimum)C max=\(.maximum)C avg=\(.average)C")' \
      <<< "${TEMPERATURE_GPU_JSON}"
    jq -r '.devices[] as $device | $device.acquisition.attempts[]? |
      select(.readable == false) |
      "[temperature][warning] \($device.bdf) \(.source) \(.phase): \(.error // "unreadable")"' \
      <<< "${TEMPERATURE_GPU_JSON}" >&2
    jq -r '.gate.failures[]? | "[temperature][error] \(.)"' <<< "${TEMPERATURE_GPU_JSON}" >&2
  fi
  return "${rc}"
}

if [[ "${PROXMOX_TEMPERATURE_GPU_LIBRARY:-0}" != 1 ]]; then
  set -euo pipefail
  temperature.gpu.main "$@"
fi
