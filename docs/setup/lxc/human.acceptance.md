# 0.0.7 LXC/Samba human acceptance

This record summarizes the completed human acceptance of the 0.0.7 isolated
ZFS-backed Samba ingest feature. It records reusable behavior rather than one
deployment's hostname, addresses, interface names, bridge names, container ID,
dataset name, share name, or credentials. Exact command output, rollback
artifacts, and private topology remain operator-owned evidence.

The accepted source candidate before release reconciliation was
`a3fb02707347228b4b3098e6518d4cd091d9beae`. Documentation-only reconciliation
does not change the runtime behavior accepted here.

## Acceptance matrix

| Area | Accepted behavior | Evidence outcome |
| --- | --- | --- |
| Host administration | Proxmox web and SSH administration remain on the discovered management path and retain the original default route. | Passed before and after network apply and host reboot. |
| Physical DATA-Link | A separate physical NIC with negotiated 10GbE carrier is selected by discovered hardware identity rather than a fixed name. | Passed; link remained up after apply and reboot. |
| Host data bridge | The selected physical DATA-Link is attached to an operator-selected bridge. The bridge is untagged and has no host IP address or gateway. | Passed; bridge membership was forwarding and both ifupdown2 no-action checks were warning-free. |
| LXC roles | The existing management interface remains the sole default-route interface. A separate static data interface is attached to the DATA bridge with no gateway or VLAN tag. | Passed in PVE configuration and live guest route/address state. |
| Network transaction | Preview, apply, semantic verification, and rollback ownership use one normalized LXC NIC representation. | Passed; generated field order and PVE-added fields no longer cause false verification failure. |
| Address safety | Bare host input is normalized with the selected prefix, subnet/broadcast values are rejected, and duplicate probing is required before mutation. | Passed with the required `iputils-arping` dependency present. |
| Storage | An existing accepted ZFS dataset is bind-mounted into an unprivileged LXC and exposed to a mapped non-login service identity through access and default ACLs. | Passed for mount persistence, read/write operations, ACLs, and xattrs. |
| Samba share | Each selected mount produces one operator-named share. Guests can list and read; only the selected authenticated account can write through `write list`. | Passed for guest read/write denial and authenticated create, rename, and delete. |
| Samba binding | SMB3 TCP 445 listens only on loopback and the selected data-role interface. NetBIOS and service discovery remain disabled. | Passed before and after reboot. |
| Samba write semantics | The managed configuration does not set `aio write behind`. Normal Samba asynchronous I/O remains available without acknowledging write-behind data before the backing filesystem accepts it. | Passed by effective-configuration review. |
| Container hardening | SSH services and sockets are stopped and masked; temporary login accounts are locked; operators use the Proxmox console or `pct exec`. | Passed before and after reboot. |
| Firewall authority | Proxmox firewall controls host and virtual-NIC boundaries. Conflicting host UFW is retired after rule validation; UFW inside the LXC remains default-deny and role-scoped. | Passed for management access, SMB data access, DHCP/DNS egress, and denied unapproved traffic. |
| Temporary egress | Reviewed URL prefixes become revocable static destination IP/port rules; redirects are refused and revoke restores default-deny. | Passed for apply, fetch policy, and revoke. |
| Persistence | The LXC and the complete Proxmox host were rebooted, followed by route, bridge, carrier, mount, ACL, firewall, Samba, and ZFS-health checks. | Passed. |
| Data transfer | A mixed workload containing many small files and several large files, plus a separate large compressed file, completed over the DATA-Link into the ZFS-backed share. | Passed as functional and sustained-transfer evidence. |

## Safety invariants

- Site values are discovered or explicitly selected; acceptance-system values
  are not implementation defaults.
- The host receives no address or gateway on the data bridge.
- The LXC has exactly one default route, owned by its management/egress role.
- The data role carries SMB traffic only and never becomes an Internet route.
- Bridge write/apply requires out-of-band acknowledgement, a checksummed
  backup, warning-free parser and reload-plan checks, and post-apply
  management-route verification.
- Guest network mutation records immutable intent, validates immediately
  before apply, and removes only a semantically matching feature-owned NIC on
  rollback.
- Existing dataset ownership is preserved; mapped access uses ACLs rather than
  recursive ownership replacement, host-root mapping, or mode 0777.
- Credentials and exact private topology are excluded from persistent public
  evidence.
- Proxy-backed egress, host addressing on the DATA-Link, and container SSH are
  outside the accepted 0.0.7 feature boundary.

## Automated candidate evidence

- GitHub Actions run
  [37330571567](https://github.com/devs-guide/proxmox/actions/runs/37330571567)
  validated candidate `a3fb02707347228b4b3098e6518d4cd091d9beae`, built the
  immutable Pages artifact, and passed the release, runtime, feature, and
  dependency contracts.
- Guarded publication run
  [37331089695](https://github.com/devs-guide/proxmox/actions/runs/37331089695)
  authorized `feature/lxc-samba-0.0.7` at that exact SHA, deployed artifact
  `pages-a3fb02707347228b4b3098e6518d4cd091d9beae`, and passed published-Pages
  verification.

These hosted runs establish source and publication provenance. The human
matrix above establishes the operational result; it is not a claim that every
deployment will reproduce one acceptance system's throughput.

## Release reconciliation

The issue-to-fix history is maintained in
[`0.0.7.change-ledger.tsv`](0.0.7.change-ledger.tsv). Before tagging, a fresh
GitHub-hosted validation run must pass for the final documentation candidate,
and the exact release title and body must receive human review under
[`../../release/publication.md`](../../release/publication.md).
