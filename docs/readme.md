# Published Proxmox Entrypoints and PVE 9 Bootstrap

This is the operator entrypoint for a fresh PVE 9.x / Debian Trixie host. Every
command uses published GitHub Pages artifacts. A repository checkout is never
required on the Proxmox server.

## Contents

- [Entrypoint index](#entrypoint-index)
- [Fresh-host bootstrap](#fresh-host-bootstrap)
- [Post-bootstrap verification](#post-bootstrap-verification)
- [AMDGPU host setup](#amdgpu-host-setup)
- [AMD temperature and passthrough](#amd-temperature-and-passthrough)
- [Human acceptance](#human-acceptance)

## Entrypoint index

| Published path | Purpose | Mode | Status |
| --- | --- | --- | --- |
| 9.1.sh | PVE 9.x/Trixie setup, packages, and baseline hardening | Mutating | Publish from Pages |
| 6.4.sh | Legacy PVE 6.4/Buster bootstrap | Mutating | Published |
| setup.gpu.amd.sh | PVE 9 native AMDGPU repair, check, and blacklist | Mutating | Publish with this change |
| setup/temperature.sh | Temperature dispatcher; v1 supports GPU only | Read-only | Publish with this change |
| setup/temperature/gpu.sh | Direct GPU driver/hwmon temperature gate | Read-only | Publish with this change |
| setup/vm/gpu.sh | GPU inventory and reviewed passthrough workflow | Mixed | Publish with complete closure |
| setup/storage/zfs.sh | Local ZFS discovery/planning/apply workflow | Mixed | Published |
| setup/vm/restore.sh | VM restore workflow | Mixed | Published |
| setup/vlan.sh | Proxmox VLAN setup | Mutating | Published |
| setup/network.sh | Proxmox network setup | Mutating | Published |
| setup/lxc/debian.sh | Debian LXC setup | Mutating | Published |
| setup/lxc/samba.sh | Samba LXC setup | Mutating | Published |
| setup.cli.codex.sh | Optional Codex CLI setup | Mutating | Published |

Mixed runners may expose read-only actions, but mutating actions must be
downloaded and inspected before execution.

## Fresh-host bootstrap

Run from a privileged shell with trusted LAN or out-of-band access:

~~~bash
set -o pipefail
wget -qO- https://devs-guide.github.io/proxmox/9.1.sh | bash
~~~

The 9.1.sh name denotes the PVE 9.x compatibility lane, not an exact
pve-manager minor. It validates PVE 9 and Trixie before applying repositories,
safe upgrades, packages, users, SSH, security services, sysctl, power, logging,
and certificates. It prints BOOTSTRAP COMPLETE only after the playlist finishes.

Credential defaults are deliberately LAN-oriented:

- app:app
- agent:agent
- proxmox:proxmox
- root:root

The static setting is bootstrap_default_password_mode: username. Valid modes
are username, preserve, and locked; username remains the published default and
uses update_password: always. A streamed run can override it deliberately:

~~~bash
set -o pipefail
wget -qO- https://devs-guide.github.io/proxmox/9.1.sh |
  PROXMOX_BOOTSTRAP_PASSWORD_MODE=preserve bash
~~~

The baseline does not assume 10.0.0.0/24 or enable UFW without an explicit
management range:

~~~bash
set -o pipefail
wget -qO- https://devs-guide.github.io/proxmox/9.1.sh |
  PROXMOX_MANAGEMENT_SUBNETS=10.0.0.0/24 PROXMOX_UFW_IPV6=true bash
~~~

Use comma-separated CIDRs for multiple management networks. RDP is closed by
default; enabling it requires PROXMOX_ALLOW_RDP=true. Keep the current session
and a tested second or out-of-band session available while changing access.

## Post-bootstrap verification

Confirm the completion marker and command exit status, then verify:

~~~bash
pveversion --verbose
systemctl --failed
test ! -e /run/reboot-required || echo "reboot required"
pvesm status
lvs -a -o lv_name,vg_name,lv_size,segtype,data_percent,metadata_percent,lv_attr
df -h / /boot/efi
~~~

For the observed single-disk installation, expect a 30 GiB root LV, 4 GiB
swap, and approximately 395.9 GiB in the pve-data thin pool. The RO=1 value
shown for that mapping by lsblk is not by itself evidence of a broken pool.
Do not run the ZFS workflow against the operating-system disk.

If the safe upgrade installed a kernel or /run/reboot-required exists, reboot
and repeat service and storage checks before GPU work. Node.js is disabled in
this lane unless explicitly enabled; the runtime probe does not install Node.

## AMDGPU host setup

~~~bash
set -o pipefail
wget -qO- https://devs-guide.github.io/proxmox/setup.gpu.amd.sh | sudo bash

set -o pipefail
wget -qO- https://devs-guide.github.io/proxmox/setup.gpu.amd.sh |
  sudo bash -s -- --check
~~~

The default action repairs the stock PVE kernel module and `pve-firmware`.
When the kernel names a missing AMD blob, the runner extracts only that file
from `firmware-amd-graphics`; it does not install the conflicting Debian
package. The runner never reboots and prints a recommendation when one is
needed.

After reviewing native temperatures, an operator with tested out-of-band
access may disable both AMD host drivers globally:

~~~bash
set -o pipefail
wget -qO- https://devs-guide.github.io/proxmox/setup.gpu.amd.sh |
  sudo bash -s -- --blacklist --yes
~~~

Remove the managed blacklist from the same endpoint:

~~~bash
set -o pipefail
wget -qO- https://devs-guide.github.io/proxmox/setup.gpu.amd.sh |
  sudo bash -s -- --unblacklist --yes
~~~

Blacklisting does not configure VFIO or attach a VM.

## AMD temperature and passthrough

### 1. Read-only temperature gate

~~~bash
set -o pipefail
wget -qO- https://devs-guide.github.io/proxmox/setup/temperature.sh |
  bash -s -- --component gpu --vendor amd --require-driver amdgpu --require-readable --reject-boot-vga --samples 3 --output json
~~~

The JSON records PCI identity, current driver, boot_vga, hwmon labels,
individual Celsius samples, and minimum, maximum, and average. The runner does
not install packages, load modules, change firmware, or enforce a universal
temperature threshold. A human decides whether readings are acceptable.

### 2. Read-only inventory

~~~bash
set -o pipefail
wget -qO- https://devs-guide.github.io/proxmox/setup/vm/gpu.sh |
  bash -s -- --action inventory --release 9.1 --output json
~~~

Review all display and companion functions, current drivers, IOMMU groups,
VM assignments, and the host boot GPU.

### 3. Download before mutation

~~~bash
wget -O ./setup.vm.gpu.sh https://devs-guide.github.io/proxmox/setup/vm/gpu.sh
chmod 0755 ./setup.vm.gpu.sh
less ./setup.vm.gpu.sh
~~~

For a host where every AMD GPU is VM-only and none is boot_vga, preview:

~~~bash
sudo bash ./setup.vm.gpu.sh --action prepare --release 9.1 --binding early --blacklist-amd --allow-host-display-loss --dry-run --output json
~~~

After reviewing the captured Celsius evidence, apply with both confirmations:

~~~bash
sudo bash ./setup.vm.gpu.sh --action prepare --release 9.1 --binding early --blacklist-amd --allow-host-display-loss --confirm-temperature-reviewed --yes
~~~

The runner recollects evidence before a new global AMD preparation, stores it
in managed host state, and rejects boot GPUs, missing amdgpu, or unreadable
sensors. After reboot, vfio-pci ownership is expected and host hwmon readings
are no longer expected. Use exact-BDF binding when an AMD GPU stays host-owned.
AMD prepare and attach mutations require --confirm-temperature-reviewed; an
automatic attachment recollects the selected GPU immediately before mutation.

Never stream prepare, attach, detach, or unprepare through wget | bash.

## Human acceptance

Before release promotion, a human tests the exact published feature commit:

1. Run or rerun the bootstrap and confirm BOOTSTRAP COMPLETE.
2. Reboot if required; validate services, LVM-thin storage, SSH, and firewall.
3. Stream `setup.gpu.amd.sh` from its Pages endpoint, run its default repair,
   and reboot only when the runner recommends it.
4. Stream the endpoint with `--check` and review every AMD temperature.
5. If all AMD GPUs are VM-only, stream `--blacklist --yes` through iDRAC and
   reboot when ready.
6. Run GPU inventory, then download and inspect the passthrough runner.
7. Run hardware and VM preflight and the preparation dry-run.
8. Apply preparation and verify vfio-pci after the operator-controlled reboot.
9. Attach one physical GPU to one stopped Q35 VM and test its guest driver.
10. Stop and start the guest, detach, unprepare, reboot, and confirm amdgpu and
   temperature readings return.

Do not run host acceptance on a local macOS workstation. Do not create a
release tag until the human-operated remote PVE sequence passes.
