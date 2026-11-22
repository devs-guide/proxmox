#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "${FIXTURE_DIR}"' EXIT
mkdir -p "${FIXTURE_DIR}/bin"

cat > "${FIXTURE_DIR}/os-release" <<'EOF'
ID=debian
VERSION_CODENAME=trixie
EOF

cat > "${FIXTURE_DIR}/bin/pveversion" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_PVE_VERSION:-pve-manager/9.2.1/test}"
EOF
cat > "${FIXTURE_DIR}/bin/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FAKE_CONTAINER:-}" ]]; then printf '%s\n' "${FAKE_CONTAINER}"; exit 0; fi
exit 1
EOF
cat > "${FIXTURE_DIR}/bin/getent" <<'EOF'
#!/usr/bin/env bash
name="${3:-${2:-}}"
case " ${FAKE_USERS:-root app agent proxmox} " in
  *" ${name} "*) printf '%s:x:1000:1000::/home/%s:/bin/bash\n' "${name}" "${name}" ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "${FIXTURE_DIR}/bin/"*

run_node_function() {
  local function_name="$1"
  shift
  PATH="${FIXTURE_DIR}/bin:${PATH}" \
  PROXMOX_RUNNER_SOURCE_ONLY=1 \
  PROXMOX_TEST_OS_RELEASE_PATH="${FIXTURE_DIR}/os-release" \
  bash -c 'source "$1"; shift; "$@"' bash "${ROOT}/setup/cli/node.sh" "${function_name}" "$@"
}

run_node_function require.pve9.trixie.host

if FAKE_PVE_VERSION='pve-manager/8.4.1/test' run_node_function require.pve9.trixie.host >/dev/null 2>&1; then
  echo '[pve_tooling_policy_test][error] PVE 8 was accepted'
  exit 1
fi
if FAKE_CONTAINER='lxc' run_node_function require.pve9.trixie.host >/dev/null 2>&1; then
  echo '[pve_tooling_policy_test][error] LXC was accepted as a native PVE host'
  exit 1
fi
if FAKE_USERS='root app agent' run_node_function require.managed.accounts >/dev/null 2>&1; then
  echo '[pve_tooling_policy_test][error] partial managed account set was accepted'
  exit 1
fi
FAKE_USERS='root app agent proxmox' run_node_function require.managed.accounts

PROXMOX_RUNNER_SOURCE_ONLY=1 \
PROXMOX_TEST_OS_RELEASE_PATH="${FIXTURE_DIR}/os-release" \
PROXMOX_CLI_NODE_MODE=upgrade \
TMP_DIR="${FIXTURE_DIR}/upgrade" \
bash -c 'source "$1"; write.extra.vars' bash "${ROOT}/setup/cli/node.sh"
grep -Fq 'node_install_policy: "always"' "${FIXTURE_DIR}/upgrade/cli.node.extra-vars.yml"

PROXMOX_RUNNER_SOURCE_ONLY=1 \
PROXMOX_TEST_OS_RELEASE_PATH="${FIXTURE_DIR}/os-release" \
PROXMOX_CLI_NODE_MODE=apply \
TMP_DIR="${FIXTURE_DIR}/apply" \
bash -c 'source "$1"; write.extra.vars' bash "${ROOT}/setup/cli/node.sh"
grep -Fq 'node_install_policy: "if_missing_or_too_old"' "${FIXTURE_DIR}/apply/cli.node.extra-vars.yml"
grep -Fq 'node_install_scope: "shared"' "${FIXTURE_DIR}/apply/cli.node.extra-vars.yml"
grep -Fq 'node_shared_nvm_dir: "/usr/local/lib/nvm"' "${FIXTURE_DIR}/apply/cli.node.extra-vars.yml"

grep -Fq 'state: present' "${ROOT}/ansible/debian/users.yml"
grep -Fq 'node_runtime_ok=1' "${ROOT}/ansible/debian/node.yml"
grep -Fq "node_install_policy == 'always'" "${ROOT}/ansible/debian/node.yml"
grep -Fq 'node_realpath=/root/' "${ROOT}/ansible/debian/node.yml"

echo '[pve_tooling_policy_test][ok] PVE guards, account gates, and Node mode policy are enforced'
