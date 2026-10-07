# ZFS-backed Samba ingest deployment (feature 0.0.7)

This is the operator runbook for the 0.0.7 feature. All site values
are discovered or confirmed; examples are not defaults. Run every `preflight`
before its corresponding mutation and keep physical or out-of-band console
access during host network/firewall changes.

For the networking-only command sequence and acceptance checks, see
[`networking.md`](networking.md).

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
2. Discover, select, and activate the separate physical DATA-Link NIC:

   ```bash
   wget -qO- https://devs-guide.github.io/proxmox/setup/network-link.sh | bash -s -- preflight
   wget -qO- https://devs-guide.github.io/proxmox/setup/network-link.sh | bash -s -- up
   ```

   The runner distinguishes an administratively down NIC from an active NIC
   without physical carrier. Missing carrier identifies a cable or peer-port
   problem and blocks bridge apply.

3. Discover and apply the host data bridge after reviewing the candidate and
   confirming OOB access. Choose `untagged` for a dedicated local LAN; the
   host bridge receives no IP, gateway, tag, or VLAN awareness. A `vmbrN` name
   in this mode is a Linux bridge name, not a VLAN ID.

   ```bash
   wget -qO- https://devs-guide.github.io/proxmox/setup.vlan.sh | bash -s -- preflight
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
   slot replacement, rejects subnet and broadcast addresses, probes the host
   address before preview and again immediately before apply, verifies the
   running guest after hot-apply, and asks before restarting only when runtime
   evidence shows activation is pending. A bare host address receives the
   configured default prefix (`/24` unless overridden) and is displayed
   alongside its derived subnet. The baseline installs the required
   `iputils-arping` package. A declined or failed restart rolls the new NIC back.
   Non-interactive restart requires
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
   cluster, or LXC inbound ACCEPT rules. Host default policy is set at the
   cluster scope supported by the Proxmox API; node scope is enabled without
   unsupported policy fields. When the LXC has a DHCP management NIC, the
   guest firewall's DHCP option is enabled so lease renewal survives its
   default-DROP inbound policy. If legacy host UFW is active, preflight reports
   it and apply retires it only after validating the Proxmox rules. The runner
   then rebuilds and verifies the Proxmox firewall chains; failure restores the
   firewall files and re-enables the previous host UFW policy. This host-level
   reconciliation does not replace the separate UFW policy applied inside the
   Samba LXC:

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
   its selected local CIDR. Each selected mount gets one `NAME` share: guests
   are read-only, while the authenticated Samba user is granted write access
   through `write list`. When exactly one mount is selected, the runner prompts
   for its published name; non-interactive callers can set
   `PROXMOX_SAMBA_SHARE_NAME`. Filesystem operations
   are forced to non-login `smb-ingest` UID/GID 2000; root ownership is not
   replaced. The credential menu defaults to LXC-hostname compatibility mode:
   the discovered container hostname becomes both the authenticated username
   and initial password. Select `custom username and password` to enter a
   lowercase account name and a hidden, confirmed secret instead. For
   non-interactive custom apply, set `PROXMOX_SAMBA_CREDENTIAL_MODE=custom`,
   `PROXMOX_SAMBA_AUTH_USER`, and `PROXMOX_SAMBA_AUTH_PASSWORD` as root.
   Passwords are not written to persistent facts or logs; the mode-restricted
   temporary Ansible variables file is removed on success, failure, or signal.

   UFW is reset to the dedicated-appliance policy: deny inbound and outbound,
   allow SMB only on the data role, and allow DNS/DHCP only on the egress role.
   A systemd start guard waits for that data interface to own a global IPv4
   address before `smbd` starts, and retries service startup after transient
   boot-order failures.
   SSH/SSHD services and sockets are stopped and masked, the SSH server package
   is removed, temporary `app`/`agent` logins are locked, and NetBIOS/Avahi
   discovery remains off.

   The managed configuration intentionally leaves `aio write behind` unset.
   Samba's normal asynchronous I/O support remains available, but the server
   does not acknowledge write-behind data before the backing filesystem has
   accepted it.

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

- Give each data-network client a unique static address in the selected subnet
  with no gateway on that NIC. Its management/Wi-Fi route remains its Internet path.
- Prove guest listing/reads work and guest creates fail on `NAME`.
- Prove the authenticated user can create, rename, and delete on that same `NAME`.
- Confirm the LXC has exactly one default route, TCP 22 is not listening, TCP
  445 is bound only to the data interface, and unapproved egress fails.
- Confirm the Proxmox data bridge has no host address and host ports 22/8006
  are reachable only from the management CIDR.
- Reboot the LXC and host, then repeat route, mount, ACL, Samba, firewall, and
  `zpool status` checks before release acceptance.

The generalized 0.0.7 acceptance record is
[`human.acceptance.md`](human.acceptance.md). Keep exact hostnames, addresses,
container IDs, credentials, and raw logs in the deployment's private evidence.

## Deferred proxy extension

A future, separately versioned proxy extension may consume the same egress
policy file and add exact-host/URL brokerage, redirect revalidation, checksums,
size limits, approval expiry, and audit logs. It is not part of 0.0.7 and must
not add another default route, expose Samba on the egress role, or weaken the
current static IP/port enforcement.
