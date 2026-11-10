## 0.0.1

This retained draft is the unpublished release-candidate page for the initial
Proxmox VE 6.4 / Debian Buster bootstrap. Its implementation scope matches the
published `0.0.1` release page; the draft state is preserved for historical
auditability and is not a second release.

The candidate introduced a streamed bootstrap, archived repositories,
Pages-published Ansible content, and a managed Python 3.11 / `ansible-core`
2.15 environment.

### Scope

- Release range: repository start through `0.0.1`
- State: retained GitHub draft; not published
- Target lane: Proxmox VE 6.4 / Debian Buster
- Published entrypoint represented by the draft: `bootstrap/release.6.4.sh`

### Highlights

- Established the first PVE 6.4 bootstrap candidate.
- Added archived Debian and Proxmox repository handling.
- Added a managed Ansible handoff after initial bootstrap.

### Added

- Python 3.11 and `ansible-core` 2.15 virtual-environment setup.
- Certificate regeneration with hostname and IP SANs.
- Release playlists and merged release variables.

### Changed

- Preferred the managed Ansible runtime after it became available.
- Generalized shared Debian playbooks for the 6.4 release lane.

### Fixed

- Corrected UFW, SSH, passlib, repository, and Pages publication behavior found
  during candidate development.

### Operator workflow and safety

This draft described privileged bootstrap behavior. It remains a draft and
must not be mistaken for an additional runnable release or a newer tag.

### #COMMIT

`docs: add rc 0.0.1 release notes`

### Notable commits since repository start

- `d9c487a` — ``added: `bootstrap/release.6.4.sh` ``
- `90f2f98` — `fix: archive repo urls used for older versions of proxmox`
- `687e893` — ``fix:pxmx:6.4 - python and ansible logic moved into `playbook.yml` ``
- `9715d5b` — `fix:pxmx:6.4 - prevent ssh lockouts and ease initial access`
- `5a1348f` — `fix:pxmx:6.4 - add cert regen play with IP SAN for web UI`
- `268976b` — `docs: add rc 0.0.1 release notes`

### Assets

- No additional binary assets
- Draft state, tag association, target, and asset list remain unchanged
