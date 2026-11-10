## 0.0.1

Release `0.0.1` established the first published bootstrap flow for Proxmox VE
6.4 on archived Debian Buster. It combined a streamed shell entrypoint,
Pages-published Ansible content, release-specific variables, and a managed
Python 3.11 / `ansible-core` 2.15 environment.

This page describes the historical 6.4-focused implementation. Later releases
changed the managed Python and Ansible policy without changing this tag.

### Scope

- Release range: repository start through `0.0.1`
- Target lane: Proxmox VE 6.4 / Debian Buster
- Published entrypoint: `bootstrap/release.6.4.sh`
- Managed runtime: Python 3.11 and `ansible-core` 2.15

### Highlights

- Added a Pages-hosted `wget | bash` bootstrap for legacy PVE 6.4 hosts.
- Added archived Debian and Proxmox repository handling.
- Handed execution from the system Ansible installation to a managed virtual
  environment after bootstrap.

### Added

- Release playlists and merged base, Buster, and release variables.
- Python 3.11 build/bootstrap support with pinned Ansible dependencies.
- `pveproxy` certificate regeneration with hostname and IP SANs.
- Dedicated Node/NVM handling for the 6.4 lane.

### Changed

- Generalized Debian playbooks so release directories could reuse shared tasks.
- Moved the Python/Ansible transition into the release-local bootstrap flow.
- Preferred the managed Ansible environment once it had been created.

### Fixed

- Corrected archived package sources and metadata handling for long-lived PVE 6
  hosts.
- Corrected early Pages publication, variable loading, and network-module
  failures.
- Reduced SSH lockout risk and limited UFW to the intended IPv4 LAN access for
  SSH and the Proxmox web interface.

### Operator workflow and safety

The bootstrap changes package repositories, networking policy, users, and
certificates on a privileged host. Operators are expected to keep an existing
management session available and verify LAN access before ending recovery
access.

### #COMMIT

`docs: add rc 0.0.1 release notes`

### Notable commits since repository start

- `d9c487a` — ``added: `bootstrap/release.6.4.sh` ``
- `90f2f98` — `fix: archive repo urls used for older versions of proxmox`
- `687e893` — ``fix:pxmx:6.4 - python and ansible logic moved into `playbook.yml` ``
- `9715d5b` — `fix:pxmx:6.4 - prevent ssh lockouts and ease initial access`
- `b8a3860` — `fix:pxmx:6.4 - merge vars per platform and use venv ansible`
- `1cba10a` — `fix:pxmx:6.4 - pin community.general for ansible 2.15`
- `5a1348f` — `fix:pxmx:6.4 - add cert regen play with IP SAN for web UI`
- `268976b` — `docs: add rc 0.0.1 release notes`

### Assets

- GitHub-generated source archives for tag `0.0.1`
- Pages-published PVE 6.4 bootstrap and Ansible runtime files
- No additional binary artifacts
