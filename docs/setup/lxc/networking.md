# SMB local DATA-Link setup

This runbook gives an existing Debian LXC two network roles:

- its existing management interface remains the only Internet/default-route
  path; and
- a separate physical NIC and unnumbered host bridge provide a static,
  no-gateway path for local SMB ingest traffic.

Run these commands as `root` on the Proxmox host. Keep physical or out-of-band
console access available during host network changes. Interface names, bridge
names, container IDs, addresses, and link speeds are discovered or confirmed;
examples from an acceptance system are never deployment defaults.

The physical data NIC must be separate from the management path and provide at
least 1Gbps capability. Faster links are preferred but are not required unless
the operator raises the minimum-speed policy.

## 1. Prepare the physical DATA-Link

Discover eligible physical NICs and select the local data role:

```bash
wget -qO- https://devs-guide.github.io/proxmox/setup/network-link.sh | bash -s -- preflight
```

Activate and verify the selected link:

```bash
wget -qO- https://devs-guide.github.io/proxmox/setup/network-link.sh | bash -s -- up
```

If the NIC is administratively down, the runner asks whether to bring it up.
If it is up but has no carrier, the runner stops and reports that the cable or
peer switch/network port must be connected or enabled. Bridge apply does not
continue until carrier and negotiated speed satisfy policy.

## 2. Select and validate the host data bridge

```bash
wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash -s -- preflight
```

Use `untagged` for a dedicated local LAN. In this mode the selected `vmbrN`
name is a Linux bridge name, not an 802.1Q VLAN ID. Choose VLAN-aware mode only
for a configured switch trunk and explicitly approved VLAN IDs.

The preflight runner detects feature-owned legacy blocks, revalidates stable
PCI/MAC identity, and previews a canonical candidate. Foreign bridge
configuration remains fail-closed. A complete older feature-owned block may
produce duplicate-interface or non-bridge attribute warnings in the current
configuration; these are treated as repair evidence only when they identify
the selected DATA-Link NIC or bridge.

## 3. Write and apply the data bridge

Stage the validated candidate without a live reload:

```bash
PROXMOX_VLAN_CONFIRM_OOB=YES \
  bash -c 'wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash -s -- write'
```

Then apply it:

```bash
PROXMOX_VLAN_CONFIRM_OOB=YES \
  bash -c 'wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash -s -- apply'
```

Apply delegates physical activation to the DATA-Link runner, rejects
ifupdown2 structural warnings even when the parser returns success, reloads
the candidate normally, and rolls back instead of forcing runtime bridge
membership. Before either write or apply succeeds, the installed canonical
candidate must pass `ifreload -a -s -n` and `ifreload -a -n` without warnings.
This lets the runner repair a recognized dirty baseline without weakening the
zero-warning requirement for the replacement.

Confirm that the management route remains intact and the data bridge remains
unnumbered:

```bash
ip -br link
ip -br address
ip route
bridge link
```

## 4. Discover the LXC network state

```bash
pct list
wget -qO- https://devs-guide.github.io/proxmox/setup/network.sh | bash -s -- preflight
```

Only the verified `vlan.applied.yml` state is used for new snapshots. A valid
snapshot requires a live data bridge, one qualifying physical bridge member,
no host data address, and an unchanged management route. It writes
`network.snapshot.ready`, `network.next-stage.env`, and the `latest-ready`
pointer.

If preflight reports a missing bridge, physical member, carrier, or applied
selection, return to the DATA-Link and bridge stages. An incomplete report
cannot replace the last update-ready snapshot.

## 5. Add the LXC data interface

```bash
wget -qO- https://devs-guide.github.io/proxmox/setup/network.sh | bash -s -- update
```

During selection:

- choose the existing ingest LXC;
- preserve its current management/Internet interface;
- use the update-ready data bridge;
- assign a unique static host address from a separate local subnet;
- configure no gateway on the data interface; and
- keep the Proxmox firewall flag enabled.

An address entered without a prefix, such as `10.10.0.4`, is normalized to
`10.10.0.4/24` by default; the runner then derives and displays the containing
subnet (`10.10.0.0/24`). Enter the assignable host address, not the subnet
identifier or broadcast address. Set `PROXMOX_NETWORK_DEFAULT_DATA_PREFIX`
when the local DATA-Link uses a prefix other than `/24`.

The baseline package set installs `iputils-arping`. Both preflight and update
require `arping`; update probes the normalized host address before preview and
again immediately before mutation. The runner also refuses live slot
replacement, management/data CIDR overlap, and stale snapshots. A running
container is restarted only when runtime evidence proves activation is
incomplete and the operator authorizes the restart. Check mode records a
would-change result without reporting or performing a guest mutation.

## 6. Verify host and guest routes

Replace `<CTID>` with the selected container ID:

```bash
pct config <CTID>
pct exec <CTID> -- ip -br link
pct exec <CTID> -- ip -br address
pct exec <CTID> -- ip route
```

Acceptance requires exactly one guest default route through the management
interface, one static no-gateway data interface, no host address on the data
bridge, and unchanged Proxmox management access.

Do not run `setup/lxc/network.sh` for the pure Samba ingest role. That runner
configures SSH-oriented access. The Samba runner binds TCP 445 to the selected
data interface, applies its dedicated UFW policy, and disables container SSH.
