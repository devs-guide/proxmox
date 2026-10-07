# 0.0.7 - Isolated ZFS Samba Ingest

Release `0.0.7` adds a discovery-led Debian LXC workflow for exposing an
existing, accepted ZFS dataset through a hardened Samba service on a separate
local data network. The Proxmox management path remains the sole default route
and administration path; an independently selected physical DATA-Link and
unnumbered host bridge carry SMB traffic.

The release composes host link and bridge management, transactional guest NIC
updates, unprivileged mapped storage access, Proxmox and container firewall
boundaries, one guest-read/authenticated-write Samba share, and revocable
static-destination egress. Site values remain discovered or operator-selected.

## Scope

- Release range: `0.0.6..0.0.7`
- Published host entrypoints:
  - `setup/network-link.sh`
  - `setup/vlan.sh`
  - `setup/network.sh`
  - `setup/firewall.sh`
- Published LXC entrypoints:
  - `setup/lxc/storage.sh`
  - `setup/lxc/egress.sh`
  - `setup/lxc/samba.sh`
- Human acceptance and incident evidence:
  - `docs/setup/lxc/human.acceptance.md`
  - `docs/setup/lxc/0.0.7.change-ledger.tsv`

This release consumes an existing accepted ZFS dataset. It does not create or
recreate a pool, add a host address to the DATA bridge, enable container SSH,
or include proxy egress, GPU passthrough, or Local Model Inventory.

## Highlights

- Keeps Proxmox administration on the discovered management network while
  placing SMB on a separate physical DATA-Link.
- Builds an unnumbered untagged or VLAN-aware bridge with hardware identity,
  carrier, parser, reload-plan, route, and rollback protection.
- Adds one static no-gateway data NIC to an existing LXC without replacing its
  management/egress interface.
- Maps an existing ZFS mount into an unprivileged container through ACLs rather
  than changing ownership or granting host-root access.
- Publishes one operator-named share where guests read and one authenticated
  account writes.
- Restricts TCP 445 to the data role, removes container SSH, applies layered
  firewall boundaries, and supports revocable static egress destinations.

## Safety and verification

- Network and firewall mutations require explicit review and out-of-band
  acknowledgement.
- Both ifupdown2 no-action modes must accept the generated bridge candidate
  without structural warnings.
- Guest NIC updates use immutable intent, duplicate probing, semantic
  verification, and ownership-safe rollback.
- The host receives no DATA-Link address or gateway, and the LXC keeps exactly
  one default route through its management/egress role.
- Existing storage ownership is preserved; service access uses mapped ACLs.
- The Samba role does not enable `aio write behind`.
- Human acceptance covered container and complete Proxmox-host reboot
  persistence plus mixed-file and large sequential data transfers.

## Important fixes

- Production and CI now share the parser that corrected `manual` being read as
  `ma` through layered escaping.
- Candidate rendering uses real lines and eliminates duplicate-interface,
  invalid bridge-attribute, and unrecognized-interface warnings.
- Address input accepts a bare assignable host address, applies the configured
  default prefix, rejects subnet/broadcast values, and requires
  `iputils-arping` duplicate checks.
- Ansible fallback paths no longer define overridable variables recursively.
- LXC verification compares parsed NIC meaning instead of raw PVE field order.
- Proxmox firewall policy uses supported scopes and transactionally retires a
  conflicting host UFW authority.
- Samba converges one correctly nested and serialized share after boot.

## Deferred work

- Proxy-backed URL brokerage remains unnumbered future work.
- `0.0.8`: whole-GPU passthrough inventory, preparation, attachment,
  verification, and rollback.
- `0.0.9`: Local Model Inventory.

## Release artifacts

- GitHub-generated source archives for tag `0.0.7`
- Published host/LXC runners, dependencies, and feature documentation through
  GitHub Pages
- No additional binary assets
