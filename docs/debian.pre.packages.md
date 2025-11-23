[Proxmox Guide](/readme.md) > [Debian](/01/)

# debian.pre-packages

Pre-install hardening and observability packages to layer onto a fresh Debian host **before** putting Proxmox on top. These match the Ansible catalog in `ansible/debian.packages.yml` (see `time_sync`, `security`, `networking`, and `base` groups).

## Quick install (interactive host)
```sh
apt update && \
apt install -y \
  chrony \
  ufw nftables iptables-persistent \
  unattended-upgrades apt-listchanges needrestart \
  fail2ban \
  auditd audispd-plugins \
  libpam-tmpdir libpam-passwdqc \
  ca-certificates gnupg curl sudo net-tools iproute2 openssh-server
```
> For Ansible, run `ansible-playbook ansible/debian.install.packages.yml` (defaults install all groups except `desktop_rdp_optional`).

## Package rationale
| Package | Why it’s here |
|---------|---------------|
| `chrony` | Stable time sync; better under jitter than timesyncd, crucial for clustering and logs. |
| `ufw`, `nftables`, `iptables-persistent` | Firewall front-end plus rule persistence across reboots (nftables backend). |
| `unattended-upgrades`, `apt-listchanges`, `needrestart` | Pull in and surface security fixes automatically; highlight required restarts. |
| `fail2ban` | Throttles SSH/other brute-force attempts; drop-in with `openssh-server`. |
| `auditd`, `audispd-plugins` | Baseline syscall auditing for later policy tuning and incident review. |
| `libpam-tmpdir`, `libpam-passwdqc` | Per-user `/tmp` isolation; stronger password quality checks via PAM. |
| `openssh-server`, `sudo`, `ca-certificates`, `gnupg`, `curl`, `net-tools`, `iproute2` | Remote access and essential admin tooling; TLS roots and GPG for repo/bootstrap tasks. |

## Group-by-group details
| Group | Purpose | Defaults |
|-------|---------|----------|
| `base` | Essential admin, SSH, crypto roots, and transport tools. | Enabled |
| `time_sync` | Reliable timekeeping via chrony. | Enabled |
| `security` | Hardening: firewall, auto-updates, brute-force throttling, audit, PAM hygiene. | Enabled |
| `storage` | Disk/RAID/LVM tooling and SMART. | Enabled |
| `monitoring_benchmark` | Live observability and I/O benchmarks. | Enabled |
| `networking` | Network tests, mailx/MTA, and firewall persistence. | Enabled |
| `hardware_info` | Hardware and firmware inventory. | Enabled |
| `dev_tools` | Minimal admin/developer shell and VCS. | Enabled |
| `desktop_rdp_optional` | Lightweight GUI+RDP stack. | Disabled by default |
| `performance_power` | CPU power management utilities. | Enabled |
| `firmware` | Common NIC firmware (Realtek). | Enabled |

### base
- `sudo`, `openssh-server`: Privilege escalation and remote access.
- `ca-certificates`, `gnupg`: Trust store and key management for HTTPS/repo operations.
- `curl`: Transport for bootstraps and checks.
- `lsb-release`: Release metadata for repos/scripts.
- `net-tools`, `iproute2`: Classic and modern network tools.

### time_sync
- `chrony`: Robust NTP client/server; better under loss/jitter than timesyncd.

### security
- `ufw`: Firewall front-end; use with nftables backend.
- `apparmor`, `apparmor-profiles`, `apparmor-profiles-extra`: MAC confinement with extra profiles.
- `unattended-upgrades`, `apt-listchanges`, `needrestart`: Auto-apply security fixes, surface changes and restart needs.
- `fail2ban`: SSH and service brute-force throttling.
- `auditd`, `audispd-plugins`: Syscall auditing pipeline for forensics and compliance.
- `libpam-tmpdir`: Per-user `/tmp` isolation to reduce cross-user leakage.
- `libpam-passwdqc`: Stronger password quality policy.

### storage
- `nvme-cli`, `hdparm`, `util-linux`: Drive management and core disk utilities.
- `mdadm`: Software RAID management.
- `lvm2`: Logical volume management.
- `lsscsi`: Enumerate SCSI/SAS/SATA devices.
- `smartmontools`: Drive health and SMART tests.
- `xattr`: Manage extended attributes.

### monitoring_benchmark
- `htop`, `atop`: Live process and system monitors (with logging via atop).
- `nmon`: Single-screen perf view.
- `dstat`: Flexible multi-resource stats.
- `iotop`: Per-process I/O bandwidth view.
- `fio`, `bonnie++`: Storage benchmarking and burn-in.

### networking
- `iperf3`: Bandwidth testing.
- `tree`: Handy directory visualization during triage.
- `mailutils`: Local MTA/mailx for system notices without outbound SMTP.
- `nftables`, `iptables-persistent`: Ensure firewall rules persist across reboots.

### hardware_info
- `lshw`, `dmidecode`: Inventory and firmware/hardware data.

### dev_tools
- `git`: Version control.
- `python3`: Scripting/runtime for tooling.
- `ksh`: Korn shell for legacy/ops scripts.

### desktop_rdp_optional
- `xrdp`: RDP server.
- `xfce4`, `xfce4-goodies`, `xorg`, `dbus-x11`, `x11-xserver-utils`, `task-lxde-desktop`: Lightweight desktop stack for occasional console work.

### performance_power
- `linux-cpupower`: CPU governor and frequency tooling.

### firmware
- `firmware-realtek`: NIC firmware for common Realtek adapters.

## Post-install to-do
- Enable and default-deny UFW; allow SSH; persist (`nftables` backend).
- Configure unattended-upgrades origins and email/alerting preference.
- Add basic `fail2ban` sshd jail + bantime/findtime tuned for your environment.
- Seed initial `audit.rules` (e.g., execve, identity, time change, module loads).
- Verify `chrony` peers/sources and NTP reachability.
- Review PAM changes (`/etc/security/pwquality.conf`, tmpdir defaults) for local policy.
