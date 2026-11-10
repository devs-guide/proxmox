## 0.0.4

Release `0.0.4` introduced an end-to-end Debian LXC and Samba workflow. It
created a Debian container on Proxmox, prepared its base runtime, passed through
selected host mounts, and configured a Samba workload inside the container.

The release also hardened template selection, mount visibility, SSH readiness,
static IPv4 input, guest-share rendering, and Pages dependency publication.

### Scope

- Release range: `0.0.3..0.0.4`
- Feature boundary: Debian LXC creation and in-container Samba
- Published entrypoints: `setup/lxc/debian.sh` and `setup/lxc/samba.sh`
- Default container profile: unprivileged, minimal, DHCP unless overridden

### Highlights

- Added interactive template, storage, bridge, address, and mount selection.
- Added deterministic Debian template policy from Buster through Trixie.
- Added parser-based Samba share selection with truthful per-share capability
  data.

### Added

- Proxmox playbooks for LXC creation, mount attachment, and runtime validation.
- Debian base, SSH, and Samba workload playbooks.
- Host and container runners for the two-stage workflow.

### Changed

- Standardized passed-through mounts on `/media/{LABEL}` semantics.
- Expanded validation for null-safe selections, static addressing, SSH access,
  mount visibility, and Samba browsing.
- Persisted actual share capabilities instead of assuming write access.

### Fixed

- Corrected empty mount selections, template fallback, missing SSH publication,
  scalar rootfs resolution, and bind-target creation.
- Corrected static CIDR normalization and Samba share propagation into
  `smb.conf`.
- Aligned guest defaults and browse validation with the intended anonymous LAN
  share model of this historical release.

### Operator workflow and safety

Container creation remains explicit and unprivileged by default. Mounts are
prepared and checked from both host and container views before workload use;
network and Samba exposure still require operator-selected bridge and address
inputs.

### #COMMIT

`fix:proxmox:lxc - static ip and guest samba permissions`

### Notable commits since 0.0.3

- `b1810bc` — `feature:setup:lxc:debian - ansible playbook for container creation`
- `7b88b05` — `feat:ansible:proxmox:lxc:samba - debian container and samba playbooks`
- `fd3eb18` — `fix:ansible:proxmox:lxc:debian - policy for buster→trixie template selector`
- `a871b96` — `feat:proxmox:lxc:debian - add mountpoint multi-select UI and map passthrough to /media/samba/*`
- `a52d2a1` — `fix:ansible:proxmox:lxc - align mount discovery and map share paths to /media/{LABEL}`
- `a49f094` — `fix:lxc:samba - persist selected shares and add parser-style share selection`
- `61dfa44` — `fix:lxc:debian - normalize static ipv4 input before pct create`
- `ab9acca` — `fix:proxmox:lxc - static ip and guest samba permissions`

### Assets

- GitHub-generated source archives for tag `0.0.4`
- Published Pages Debian LXC, Samba, and shared runtime files
- No additional binary artifacts
