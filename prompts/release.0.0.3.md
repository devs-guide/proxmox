## 0.0.3

Published Proxmox VLAN feature release for the new manual `ansible/proxmox/`
network-bridge workflow.

This release adds the first end-to-end VLAN feature flow for Proxmox hosts in
this repo. It introduces dedicated hardware discovery, a manual setup runner,
published feature playbooks, operator-facing NIC selection, bridge safety
assertions, and apply-time rollback protection. It also hardens the feature
through multiple follow-up fixes around management-path detection, YAML parsing,
duplicate interface guards, and live bridge attachment during `apply`.

### Scope

- Release range: `0.0.2..HEAD`
- Target lane: Proxmox manual VLAN workflow
- Management path preserved: `vmbr0`
- Published runner: `setup.vlan.sh`
- Core feature files:
  - `ansible/proxmox/helper/hardware.yml`
  - `ansible/proxmox/vlan.yml`
  - `ansible/group_vars/proxmox.yml`
  - `setup/vlan.sh`

### Highlights

- Added a dedicated Proxmox VLAN feature namespace under `ansible/proxmox/`.
- Added a manual setup runner that discovers the management plane, presents
  physical NIC candidates, persists operator selections, and runs
  `preflight` / `write` / `apply`.
- Published the runner and feature playbooks through the Pages workflow so the
  feature can be invoked remotely.
- Hardened live `apply` behavior so the selected data NIC is verified against
  the target bridge and remediation is attempted before rollback.

### Added

- `ansible/proxmox/helper/hardware.yml` for read-only NIC, bridge, and
  management-path discovery with persisted hardware facts.
- `ansible/proxmox/vlan.yml` for managed `vmbr1` creation, staged writes,
  dry-run `ifreload`, live `apply`, and rollback safety.
- `setup/vlan.sh` for interactive operator flow, TTY-safe prompts, VLAN
  selection persistence, and controlled feature execution.
- Proxmox-specific group vars and feature defaults in
  `ansible/group_vars/proxmox.yml`.
- Pages-publish and validation coverage for the Proxmox feature artifacts.

### Changed

- Introduced a readable VLAN setup UI with management path confirmation and
  ranked physical NIC selection.
- Tightened discovery and validation so the feature preserves the management
  plane on `vmbr0` and rejects unsafe data-NIC choices.
- Expanded runtime validation to cover publish wiring, selection artifacts,
  bridge-fd handling, attachment diagnostics, and rollback safeguards.
- Standardized the manual VLAN workflow around persisted hardware facts and
  operator selection files rather than implicit in-memory state.

### Fixed

- Hardened physical NIC discovery and bridge-member parsing in the Proxmox
  hardware helper.
- Fixed management discovery mismatches between the selected path and discovered
  bridge/uplink state.
- Fixed setup-runner YAML parsing issues and improved interactive UI stability.
- Prevented duplicate or conflicting selected-NIC interface stanzas.
- Fixed null bridge-membership handling inside VLAN safety assertions.
- Fixed apply-time failure modes where the selected NIC did not appear on the
  target bridge after `ifreload -a`.
- Added runtime bridge attachment remediation before rollback when `apply` left
  the selected data NIC detached from the target bridge.

### #COMMIT

`release:0.0.3 - add vlan release notes and prompt conventions`

### Commits since 0.0.2

- `ansible:proxmox:playbook - add manual VLAN, with runner`
- `feat(proxmox): add interactive VLAN feature flow and publish contract`
- `fix:ansible:proxmox: harden vlan hardware discovery`
- `fix:ansible:proxmox: improve vlan setup ui / nic discovery`
- `fix:ansible:proxmox: stabilize vlan setup ui options`
- `fix(pages): publish setup runner changes`
- `fix:ansible:proxmox: vlan management discovery conflict`
- `fix:ansible:proxmox:vlan: null error on bridge membership in VLAN guard`
- `fix:ansible:proxmox:vlan: python yaml parser not found`
- `fix:ansible:proxmox:vlan: error on duplicat vlan, down host`
- `fix:ansible:proxmox:vlan: NIC not attached to VLAN`
- `fix:ansible:proxmox:vlan: nic not attaching to vlan during apply stage`

### Assets

- `prompts/release.0.0.3.md` as the GitHub release notes attachment/body source
- No additional binary artifacts
