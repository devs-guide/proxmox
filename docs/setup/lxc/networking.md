# LXC dual-network setup

This runbook configures an existing Debian LXC with two network roles:

- its existing management interface remains the only Internet/default-route
  path; and
- a discovered physical data NIC and host bridge provide a static, no-gateway
  path for local ingest traffic.

Run these commands as `root` on the Proxmox host. Keep physical or out-of-band
console access available while changing host networking. Do not infer physical
interface names, bridge names, LXC interface slots, or guest interface names;
the runners discover them and require operator confirmation.

## 1. Discover the host network

```bash
wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash -s -- preflight
```

On PVE 9/Trixie, compatible system `python3` is sufficient. A managed Python
path or handoff marker is not a prerequisite.

## 2. Probe the selected data NIC

The probe temporarily raises only the selected unused physical link and then
restores its previous state.

```bash
wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash -s -- probe
```

## 3. Write and apply the data bridge

Choose `untagged` for an untagged switch port. The data bridge must have no host
IP address or gateway.

```bash
PROXMOX_VLAN_CONFIRM_OOB=YES \
  bash -c 'wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash -s -- write'
```

Review the generated configuration, then apply it:

```bash
PROXMOX_VLAN_CONFIRM_OOB=YES \
  bash -c 'wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash -s -- apply'
```

Confirm that the management route was preserved and that the data bridge has
no host address:

```bash
ip -br link
ip -br address
ip route
```

## 4. Discover the LXC network state

```bash
pct list
wget -qO- https://devs-guide.github.io/proxmox/setup/network.sh | bash -s -- preflight
```

## 5. Add the LXC data interface

```bash
wget -qO- https://devs-guide.github.io/proxmox/setup/network.sh | bash -s -- update
```

During selection:

- choose the existing ingest LXC;
- preserve its current management/Internet interface;
- choose the discovered data bridge;
- assign a unique static address and prefix for the local data network;
- configure no gateway on the data interface; and
- keep the Proxmox firewall flag enabled.

The runner refuses replacement of a live interface slot, probes for duplicate
IPv4 use, verifies hot activation, and asks to restart the LXC only when runtime
evidence shows activation is still pending.

## 6. Verify host and guest routes

Replace `<CTID>` with the selected container ID:

```bash
pct config <CTID>
pct exec <CTID> -- ip -br link
pct exec <CTID> -- ip -br address
pct exec <CTID> -- ip route
pct exec <CTID> -- sh -c 'ip -4 route show default; ip -4 route show'
```

Acceptance requires:

- exactly one guest default route, through the management interface;
- a static address on the data interface with no gateway;
- no host address on the data bridge; and
- the original Proxmox management route and connectivity still working.

Do not run `setup/lxc/network.sh` for the pure Samba ingest role. That runner
configures SSH-oriented container access. The Samba runner later binds TCP 445
to the selected data interface, applies its dedicated UFW policy, and disables
container SSH.
