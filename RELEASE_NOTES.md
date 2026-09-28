# 0.0.5 - Proxmox Runtime, Networking, LXC, and VM Restore

Release `0.0.5` promotes the Proxmox runtime, networking, LXC, and VM restore
work completed after `0.0.4`. It keeps the published Proxmox VE 6.4/Buster
compatibility lane while making Proxmox VE 9.1/Trixie the current host setup
lane.

## Scope

- Release range: `0.0.4..0.0.5`
- Supported release lanes:
  - Proxmox VE 6.4 / Debian Buster
  - Proxmox VE 9.1 / Debian Trixie
- Mainline implementation before release metadata: 57 commits, 52 files,
  13,849 insertions, and 264 deletions
- Published host and workload workflows:
  - Proxmox bootstrap and managed Ansible runtime
  - host network discovery, planning, apply, and verification
  - Debian LXC creation, users, network access, Samba, Node, and Codex
  - local and remote QEMU VM restore

Whole-GPU passthrough is intentionally excluded from `0.0.5` and remains the
separately reviewed `0.0.6` candidate.

## Highlights

- Updated the PVE 9.1 bootstrap to prefer native Trixie Python for the
  controller while retaining a managed Python 3.13 target runtime and pinned
  `ansible-core==2.20.5`.
- Added discovery-led Proxmox networking with persisted preflight evidence,
  explicit plans, apply-time checks, and post-apply verification.
- Split LXC setup into reusable common, Debian, users, network, Samba, Node,
  and Codex layers.
- Added recoverable VM restore tooling for SSH synchronization, archive
  inspection, transfer, temporary storage, local restore, remote restore, and
  interrupted-stage recovery.
- Added exact-candidate release validation, immutable Pages artifacts,
  explicitly confirmed feature publication, and live post-publication checks.

## Added

- `setup/network.sh` with check/apply modes backed by network preflight,
  intent, plan, update, and verification artifacts.
- `setup/lxc/users.sh`, `setup/lxc/network.sh`, and `setup/lxc/codex.sh` for
  separately managed container capabilities.
- `setup/cli.codex.sh` and its Debian playbook for the host-side Codex CLI
  installation lane.
- `setup/vm/restore.sh` for staged local or remote QEMU restore with durable
  JSON state and explicit recovery controls.
- `cli/ssh/sync.sh` for dedicated SSH key setup and guarded key rotation.
- `cli/rsync/fetch.sh` for remote archive inspection and transfer.
- `cli/storage/temp.sh` for temporary restore-storage lifecycle management.
- Release, VM restore, Pages, and runtime validators used by the publication
  workflow.

## Changed

- PVE 9.1 now configures Debian Trixie and Proxmox no-subscription repositories
  before the first package update and removes conflicting enterprise or Ceph
  source definitions.
- The PVE 9.1 controller uses native Python when it satisfies policy, while
  Ansible modules retain the release-managed target-interpreter contract.
- LXC creation uses a shared baseline and supports current Debian template
  policy through Trixie.
- The default Proxmox guest data-network strategy is high-speed-only, using
  `vmbr1` and VLAN tag `1` unless the operator selects other values.
- Published Bash helpers use explicit `.sh` paths and can bootstrap their
  declared shared dependencies.
- Pages validation and deployment are separated so pull requests and ordinary
  feature pushes validate without changing the live site.

## Fixed

- Disabled conflicting PVE enterprise sources before the first PVE 9 update.
- Corrected PVE 9 bootstrap publication paths and native-Python handoff.
- Corrected LXC network variable serialization, SFTP policy, user separation,
  sudo membership, and container runtime imports.
- Corrected network runner default detection and validation behavior.
- Added missing Ansible password-hash and network-collection dependencies to
  the validation environment.
- Hardened restore state transitions, incomplete-stage recovery, check-mode
  service behavior, and runner-Python selection.
- Ensured Pages builds validate an exact candidate and publish only the
  immutable artifact produced by that validation.

## Operator-managed defaults

The repository provides editable LAN-oriented examples. Unless overridden,
the baseline account passwords match the account names:

- `app` / `app`
- `agent` / `agent`
- `proxmox` / `proxmox`
- `root` / `root`

The default network policy assumes `10.0.0.0/24`, enables the RDP allowance,
and permits SSH and the Proxmox web UI from the configured LAN. Operators are
expected to update accounts, passwords, allowed users, subnets, ports, and
repository policy for their own environment.

No `nvidia` account is created by this release. GPU-oriented service accounts
remain optional, operator-defined configuration for the later GPU workflow.

## Validation requirements

The accepted release must have evidence for both supported lanes:

- exact-candidate CI validation and Pages dependency-graph validation;
- successful candidate Pages publication and remote validation;
- PVE 6.4 bootstrap, LAN access, disposable LXC, Samba/SFTP, and local/remote
  restore acceptance;
- PVE 9.1 bootstrap, LAN access, network preflight, disposable Trixie LXC,
  Samba/SFTP, and local/remote restore acceptance;
- interrupted and resumed remote restore coverage;
- successful second bootstrap runs on both lanes.

## Deferred to 0.0.6

The following existing feature-branch work is not part of this tag:

- whole-GPU inventory, preflight, preparation, verification, and rollback;
- exact-BDF and multi-GPU host-driver selection;
- QEMU GPU attach/detach and display-field restoration;
- PVE 6.4 and PVE 9.1 GPU adapters, schemas, fixtures, and runbooks.

## Release artifacts

- GitHub-generated source archives for tag `0.0.5`
- Published Pages bootstrap and feature runners
- No additional binary assets
