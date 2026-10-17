# 0.0.8 - Restricted DATA-Link LXC Transfers

Release `0.0.8` adds operator-selected rsync and an on-demand `iperf3`
bandwidth test between authorized clients on an existing isolated LXC data
network. It builds on the `0.0.7` ZFS-backed Samba workflow without assigning
endpoint roles, choosing storage paths, changing Proxmox management
networking, or enabling general container administration over SSH.

The feature discovers an existing directly connected static data interface,
canonicalizes the complete selected network CIDR, and configures
interface-specific TCP 22 and TCP 5201 ingress and egress for that CIDR.
Deployment names, addresses, interfaces, storage roots, account groups,
peers, source paths, and destination paths remain discovered or
operator-selected.

## Scope

- Release range: `0.0.7..0.0.8`
- LXC entrypoint: `setup/lxc/transfer.sh`
- Host boundary integration: `setup/firewall.sh` with
  `PROXMOX_FIREWALL_ENABLE_LXC_TRANSFER=1`
- Transfer helpers: `proxmox-transfer-ssh`, `proxmox-transfer-rsync`, and
  `proxmox-transfer-speed-test`
- Operator runbook: `docs/setup/lxc/transfer.md`

This release does not assign DATA-Link addresses, add a gateway, modify either
Proxmox host's management policy, or enable shell access to the containers.

## Highlights

- Uses the complete operator-selected closed-LAN CIDR rather than hard-coded
  peer `/32` rules, so any LAN client can reach the service at the network
  layer.
- Requires a separately enrolled Ed25519 key for every authorized client.
- Runs a dedicated `sshd` bound only to the selected data address and forces
  `rrsync` into one selected storage root.
- Disables passwords, root login, PTYs, shell commands, forwarding, tunneling,
  agent forwarding, and user environment changes.
- Exchanges public-only pairing bundles and pins peer server host keys.
- Preserves an existing operator-selected automation account's UID, GID,
  home, shell, and password while requiring approved storage-group membership.
- Provides a fixed, shell-free SSH handshake that proves key enrollment and
  host-key pinning before any backup path is used.
- Keeps the restricted transfer policy intact when Samba resets UFW.
- Provides a one-shot `iperf3` server bound only to the selected DATA address.
- Prevents YAML Boolean coercion from corrupting the UFW interface-specific
  `on` command token during live apply.
- Verifies the SSH listener from the local-address column so the normal
  peer-column wildcard reported by `ss` does not cause a false failure.
- Installs the OpenSSH authorized-keys command below the root-owned transfer
  configuration tree, including on legacy shifted-root filesystems.
- Keeps copy operations non-deleting and makes checksum verification a
  separate optional dry run.
- Supports preflight, prepare, apply, verify, rotate, revoke, and rollback.

## Safety and verification

- The runner refuses Proxmox-host execution and validates a static,
  directly-connected, no-gateway LXC network role.
- The allow CIDR must equal the canonical network of the selected LXC address.
- The dedicated listener must bind only to the selected data address.
- Imported peer endpoints must be members of the same selected network.
- Proxmox TCP 22 and on-demand TCP 5201 exposure is opt-in and bound to the
  selected LXC data slot.
- The supported rsync helper never requests destination deletion or source
  removal.
- Rollback removes managed runtime state and UFW rules while retaining private
  recovery identities locally.

## Deferred work

- Proxy-backed URL brokerage remains unnumbered future work.
- `0.0.9`: whole-GPU passthrough inventory, preparation, attachment,
  verification, and rollback.
- `0.0.10`: Local Model Inventory.

## Release artifacts

- GitHub-generated source archives for tag `0.0.8`
- Published runners, playbooks, CLI helpers, and feature documentation through
  GitHub Pages
- No additional binary assets
