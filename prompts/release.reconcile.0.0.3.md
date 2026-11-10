## 0.0.3

Release `0.0.3` added the first end-to-end manual VLAN workflow for Proxmox
hosts. It combined hardware discovery, operator NIC selection, managed bridge
configuration, apply-time verification, and rollback protection.

Follow-up fixes hardened management-path discovery, YAML parsing, duplicate
interface prevention, and live attachment of the selected NIC to `vmbr1`.

### Scope

- Release range: `0.0.2..0.0.3`
- Feature boundary: manual Proxmox VLAN and data-bridge setup
- Published entrypoint: `setup.vlan.sh`
- Management bridge preserved by the release: `vmbr0`

### Highlights

- Added discovery-led physical NIC selection and persisted hardware facts.
- Added preflight, staged write, apply, verification, and rollback phases.
- Published the complete runner/playbook dependency graph through Pages.

### Added

- `ansible/proxmox/helper/hardware.yml` for read-only NIC and management-path
  discovery.
- `ansible/proxmox/vlan.yml` for managed `vmbr1` configuration and rollback.
- `setup/vlan.sh` for the interactive feature flow.

### Changed

- Replaced implicit network assumptions with persisted discovery and explicit
  operator selection.
- Expanded runtime validation for bridge membership, selection artifacts, and
  rollback behavior.

### Fixed

- Corrected management-bridge conflicts, null bridge membership, missing YAML
  parsing, duplicate VLAN definitions, and detached-NIC apply results.
- Added runtime attachment remediation before rollback when `ifreload -a` left
  the selected data NIC outside the target bridge.

### Operator workflow and safety

The feature preserves the discovered management path and stages configuration
before applying it. Unsafe NIC choices and conflicting interface definitions
are rejected; apply failures retain rollback behavior to reduce remote lockout
risk.

### #COMMIT

`release:0.0.3 - proxmox vlan automation with gui for network choices`

### Notable commits since 0.0.2

- `bbfe536` — `ansible:proxmox:playbook - add manual VLAN, with runner`
- `698e841` — `feat(proxmox): add interactive VLAN feature flow and publish contract`
- `2b34909` — `fix:ansible:proxmox: harden vlan hardware discovery`
- `553a091` — `fix:ansible:proxmox: vlan management discovery conflict`
- `a5db9e3` — `fix:ansible:proxmox:vlan: error on duplicat vlan, down host`
- `7e49dc8` — `fix:ansible:proxmox:vlan: nic not attaching to vlan during apply stage`
- `e56f349` — `release:0.0.3 - proxmox vlan automation with gui for network choices`

### Assets

- GitHub-generated source archives for tag `0.0.3`
- Published Pages VLAN runner and Ansible dependencies
- No additional binary artifacts
