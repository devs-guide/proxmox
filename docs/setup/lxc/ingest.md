# ZFS-backed Samba ingest deployment (feature 0.0.7)

This is the operator runbook for the unreleased 0.0.7 feature. All site values
are discovered or confirmed; examples are not defaults. Run every `preflight`
before its corresponding mutation and keep physical or out-of-band console
access during host network/firewall changes.

The feature runners use the shared runtime detector. On PVE 9/Trixie, the
native compatible `python3` is sufficient; `/opt/ansible/py312` and its handoff
marker are not prerequisites. A missing or stale shared Ansible venv may be
repaired from system Python, but CPython is built only as an older-release
fallback when the native interpreter is below the supported minimum.

## Proxmox host sequence

1. Bootstrap the matching supported Proxmox lane when the base host still
   needs repository, package, or baseline configuration. For PVE 9/Trixie:

   ```bash
   wget -qO- https://devs-guide.github.io/proxmox/9.1.sh | bash
   ```

   This full baseline is not required merely to manufacture a managed Python
   when compatible system Python and the shared Ansible runtime are already
   available. Run the existing ZFS inventory/verification workflow from
   `docs/setup/storage/zfs/human.acceptance.md`. An already accepted pool is
   verified, not recreated.
2. Discover physical NICs and the management default-route path:

   ```bash
   wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash -s -- preflight
   ```

3. Select the unused physical data NIC. Use `probe` to bring only that link up
   temporarily and restore its prior state. Then use `write` and `apply` after
   reviewing the generated selection and confirming OOB access. Choose
   `untagged` for an unmanaged switch; the host data bridge receives no IP,
   gateway, tag, or VLAN awareness.

   ```bash
   wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash -s -- probe
   PROXMOX_VLAN_CONFIRM_OOB=YES \
     bash -c 'wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash -s -- write'
   PROXMOX_VLAN_CONFIRM_OOB=YES \
     bash -c 'wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash -s -- apply'
   ```

4. Create or select the Debian LXC with `setup/lxc/debian.sh`. Keep it
   unprivileged with nesting and FUSE disabled. Select the ZFS host mount; do
   not infer a CTID, bridge, or guest interface name.

   ```bash
   wget -qO- https://devs-guide.github.io/proxmox/setup/lxc/debian.sh | bash
   ```

5. Run `setup/network.sh preflight`, then `setup/network.sh update`. The update
   preserves the discovered default-route/egress NIC and adds one confirmed
   static data NIC with `firewall=1`, no gateway, and no tag. It refuses live
   slot replacement, probes the address for duplicates, verifies the running
   guest after hot-apply, and asks before restarting only when runtime evidence
   shows activation is pending. A declined/failed restart rolls the new NIC
   back. Non-interactive restart requires
   `PROXMOX_NETWORK_ALLOW_LXC_RESTART=1`.

   ```bash
   wget -qO- https://devs-guide.github.io/proxmox/setup/network.sh | bash -s -- preflight
   wget -qO- https://devs-guide.github.io/proxmox/setup/network.sh | bash -s -- update
   ```
6. Map the fixed container service UID/GID 2000 onto the selected host bind
   mount without changing ownership:

   ```bash
   wget -qO- https://devs-guide.github.io/proxmox/setup/lxc/storage.sh | bash -s -- preflight
   wget -qO- https://devs-guide.github.io/proxmox/setup/lxc/storage.sh | bash -s -- apply
   ```

   `apply` sets access and default ACLs at the dataset root for new ingest.
   If existing content also needs mapped access, run the explicit,
   restartable `apply-recursive` mode during a maintenance window. It batches
   directories and files separately and still preserves every owner.

7. Restrict Proxmox SSH (22) and web administration (8006) to the discovered
   private management CIDR. The same runner discovers the selected LXC's
   static no-gateway PVE NIC slot, enables that guest firewall boundary, and
   permits only its data CIDR to TCP 445. Apply requires
   `PROXMOX_FIREWALL_CONFIRM_OOB=YES` and refuses pre-existing broad host,
   cluster, or LXC inbound ACCEPT rules:

   ```bash
   wget -qO- https://devs-guide.github.io/proxmox/setup/firewall.sh | bash -s -- preflight
   PROXMOX_FIREWALL_CONFIRM_OOB=YES \
     bash -c 'wget -qO- https://devs-guide.github.io/proxmox/setup/firewall.sh | bash -s -- apply'
   ```

## In-container sequence

Open the LXC through the Proxmox console or `pct enter`; container SSH is not
part of this role. Cache the egress policy helper before applying the firewall:

```bash
wget -qO /root/setup.lxc.egress.sh https://devs-guide.github.io/proxmox/setup/lxc/egress.sh
chmod 0700 /root/setup.lxc.egress.sh
```

1. Apply Samba inside the LXC:

   ```bash
   wget -qO- https://devs-guide.github.io/proxmox/setup/lxc/samba.sh | bash -s -- preflight
   wget -qO- https://devs-guide.github.io/proxmox/setup/lxc/samba.sh | bash -s -- apply
   ```

   The runner discovers the egress interface from the default route and asks
   for the separate data interface. It binds TCP 445 only to the data role and
   its selected local CIDR. Each selected mount gets `NAME_RO` (guest,
   read-only) and `NAME_RW` (authenticated, read-write). Filesystem operations
   are forced to non-login `smb-ingest` UID/GID 2000; root ownership is not
   replaced. The runner requires an operator-selected authenticated account
   and prompts for its secret during apply. For non-interactive apply, set
   `PROXMOX_SAMBA_AUTH_USER` and `PROXMOX_SAMBA_AUTH_PASSWORD` as root. The
   hostname compatibility password is disabled unless explicitly opted into
   for temporary migration testing.

   UFW is reset to the dedicated-appliance policy: deny inbound and outbound,
   allow SMB only on the data role, and allow DNS/DHCP only on the egress role.
   SSH/SSHD services and sockets are stopped and masked, the SSH server package
   is removed, temporary `app`/`agent` logins are locked, and NetBIOS/Avahi
   discovery remains off.

2. Add a static destination approval before a download, then remove it when
   the transfer window closes:

   ```bash
   PROXMOX_LXC_EGRESS_URLS='https://approved.example/path/' \
     /root/setup.lxc.egress.sh preflight
   PROXMOX_LXC_EGRESS_URLS='https://approved.example/path/' \
     /root/setup.lxc.egress.sh apply
   ingest-fetch https://approved.example/path/file.tar
   /root/setup.lxc.egress.sh revoke
   ```

   The helper validates URL prefixes, resolves them to static IPv4/port rules,
   writes `/etc/proxmox-ingest/egress.allow`, and installs `ingest-fetch`.
   The current static policy refuses redirects; approve and fetch the final
   destination explicitly. `revoke` removes every rule owned by this helper
   while leaving default-deny active.

## Client and acceptance checks

- Give each 10Gb client a unique static address in the selected data subnet
  with no gateway on that NIC. Its 1Gb/Wi-Fi route remains its Internet path.
- Prove guest listing/reads work and guest creates fail on `NAME_RO`.
- Prove the authenticated user can create, rename, and delete on `NAME_RW`.
- Confirm the LXC has exactly one default route, TCP 22 is not listening, TCP
  445 is bound only to the data interface, and unapproved egress fails.
- Confirm the Proxmox data bridge has no host address and host ports 22/8006
  are reachable only from the management CIDR.
- Reboot the LXC and host, then repeat route, mount, ACL, Samba, firewall, and
  `zpool status` checks before release acceptance.

## Proxy extension contract

The final 0.0.7 proxy extension will consume the same egress policy file and
add exact-host/URL brokerage, redirect revalidation, checksums, size limits,
approval expiry, and audit logs. It must not add another default route, expose
Samba on the egress role, or weaken the current static IP/port enforcement.
