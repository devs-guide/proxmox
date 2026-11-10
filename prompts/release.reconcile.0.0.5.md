## 0.0.5

Release `0.0.5` consolidated the Proxmox runtime, networking, LXC, and VM
restore work completed after `0.0.4`. It retained the PVE 6.4/Buster lane while
making PVE 9.1/Trixie the current bootstrap lane.

The release added recoverable local and remote QEMU restore workflows alongside
discovery-led host networking and reusable container setup layers.

### Scope

- Release range: `0.0.4..0.0.5`
- Supported lanes: PVE 6.4/Buster and PVE 9.1/Trixie
- Published feature areas: host networking, Debian LXC, Samba, users, SFTP,
  Node, Codex, SSH synchronization, temporary storage, rsync, and VM restore
- Whole-GPU passthrough and local ZFS provisioning are outside this tag.

### Highlights

- Added a PVE 9.1 bootstrap with Trixie-native controller Python and a managed
  target runtime.
- Added discovery-led host network planning, apply, and verification.
- Added resumable, integrity-checked local and remote QEMU restore.
- Separated validation artifacts from main-only Pages deployment.

### Added

- `setup/network.sh` and its network preflight, intent, plan, and verification
  artifacts.
- Reusable LXC users, network, Samba, Node, and Codex entrypoints.
- `setup/vm/restore.sh` plus SSH, rsync, and temporary-storage helpers.
- Exact-candidate release, runtime, VM restore, and Pages validation.

### Changed

- Configured Trixie and the PVE no-subscription repository before the first
  package update while removing conflicting enterprise definitions.
- Split host, Debian, and LXC runtime responsibilities.
- Standardized published helpers on explicit `.sh` paths.
- Kept restored VMs stopped unless `--start` was explicitly selected.

### Fixed

- Corrected PVE 9 publication and Python handoff behavior.
- Corrected LXC network serialization, SFTP, sudo, user ownership, and runtime
  imports.
- Corrected VM restore preflight, SSH key comparison, JSON state transitions,
  incomplete-stage recovery, and local archive ownership boundaries.
- Added missing Ansible password-hash and network-collection dependencies to CI.

### Operator workflow and safety

VM restore rejects conflicting or unsafe destinations, keeps input archives
unchanged, verifies complete archives before `qmrestore`, and only cleans up
resources proven to be feature-owned. Network and VLAN mutations remain
separately authorized operations.

### #COMMIT

`Merge pull request #3 from devs-guide/feature/release-0.0.5`

### Notable commits since 0.0.4

- `78a6bd4` — `fix:bootstrap:pve9 - disable enterprise repos before first apt update`
- `3ea6137` — `feat(proxmox:network): update flow for guest data NICs with publish/validation wiring`
- `d06178f` — `fix:setup/lxc/{features} all now use common base, sudo not root install`
- `c0c3605` — `feature: ssh sync keys, proxmox vm restore tooling`
- `2b2a557` — `feature: publish vm restore helpers with .sh paths`
- `a44cae2` — `feature: replace restore metadata with JSON`
- `d53b4c9` — `fix: recover incomplete VM restore stages`
- `b6fc806` — `feat: add local VM restore mode`
- `2df0320` — `ci: gate 0.0.5 validation and Pages deploy`
- `f2120ee` — `Merge pull request #3 from devs-guide/feature/release-0.0.5`

### Assets

- GitHub-generated source archives for tag `0.0.5`
- Published Pages bootstrap, networking, LXC, and VM restore graph
- No additional binary artifacts
