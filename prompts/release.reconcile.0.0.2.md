## 0.0.2

Release `0.0.2` unified the managed Ansible bootstrap across the Proxmox VE
6.4 and 9.x lanes. It standardized the target interpreter on Python 3.12,
kept the controller in `/opt/ansible-venv`, and pinned `ansible-core` 2.20.5.

The release also added the PVE 9.1/Trixie bootstrap and made package, user, and
SSH policy safe to apply through the shared release flow.

### Scope

- Release range: `0.0.1..0.0.2`
- Target lanes: PVE 6.4/Buster and PVE 9.1/Trixie
- Managed target runtime: `/opt/ansible/py312/bin/python`
- Managed controller runtime: `/opt/ansible-venv`

### Highlights

- Added a Trixie/PVE 9.1 compatibility lane beside the archived 6.4 lane.
- Standardized Python 3.12, Ansible 13, and `ansible-core` 2.20.5 policy.
- Added an explicit raw bootstrap and handoff path for the older system Python
  on PVE 6.4.

### Added

- Debian Trixie and Proxmox 9.1 repository configuration.
- Host-flavor package gating and simulated checks against Proxmox meta-package
  removal.
- Shared package-catalog and managed-runtime validation.

### Changed

- Kept controller and target Python responsibilities separate.
- Moved shared user definitions into common scope for SSH `AllowUsers` policy.
- Kept `udftools` canonical in the package catalog and refreshed catalog data
  on reruns.

### Fixed

- Corrected the PVE 6.4 handoff by avoiding unsupported early module execution.
- Corrected shared SSH-user derivation, package exclusions, passlib ordering,
  and managed-runtime recursion.
- Reduced unnecessary changes on repeated user, network, and certificate runs.

### Operator workflow and safety

Both release lanes perform privileged repository, package, account, SSH, and
firewall changes. The 6.4 lane deliberately uses a raw bridge until the managed
interpreter is ready; removing that handoff would break legacy hosts.

### #COMMIT

`fix:ansible:shared - reduce rerun for playbooks: users, network, certs`

### Notable commits since 0.0.1

- `872c9f6` — `proxmox:9.1 - add trixie bootstrap`
- `170b03e` — `proxmox:9.1 - make package install PVE-safe and simulate meta removals`
- `3898a0c` — `fix:pxmx:ansible - build freeze shared python and ansible bootstrap`
- `8f338ff` — `refactor: shared python:3.12 and ansible:13 across releases`
- `101a3dd` — `fix:ansible:pxmx:6.4 - replace apt package facts with dpkg check`
- `fe99b35` — `fix:pxmx:shared - rename udf-tools to udftools in package catalog`
- `49d0606` — `fix:ansible:shared - user defs shared scope for ssh allowusers`
- `d6f251c` — `fix:ansible:shared - reduce rerun for playbooks: users, network, certs`

### Assets

- GitHub-generated source archives for tag `0.0.2`
- Pages-published bootstrap and Ansible files for both release lanes
- No additional binary artifacts
