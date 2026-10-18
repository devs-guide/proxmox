# Restricted LXC rsync and bandwidth testing on the DATA-Link

Release 0.0.8 pairs operator-selected Debian LXCs for key-only rsync and an
on-demand `iperf3` test on an existing isolated data network. It does not
contain a site map or assign source and destination roles. Addresses,
interfaces, CTIDs, storage roots, peers, and copy paths are discovered or
entered by the operator.

The selected directly connected IPv4 network is the firewall boundary. TCP 22
and TCP 5201 are admitted on the selected DATA interface for that complete
CIDR, not for hard-coded peers. SSH still requires an enrolled Ed25519 key,
and TCP 5201 has no listener until an operator starts the one-shot speed test.

The SSH service forces the distro `rrsync` command into the selected transfer
root. It does not provide a shell, password login, PTY, forwarding, tunneling,
or administrative SSH. Use the Proxmox LXC console for administration.

## 1. Open the LXC boundary

Run the firewall runner on each applicable Proxmox host. Select its LXC and
discovered DATA NIC slot; do not assign an address or gateway to the host data
bridge.

```bash
PROXMOX_FIREWALL_CTID=CTID \
PROXMOX_FIREWALL_LXC_DATA_SLOT=NET_SLOT \
PROXMOX_FIREWALL_ENABLE_LXC_TRANSFER=1 \
./setup/firewall.sh preflight
```

Review the complete derived DATA CIDR, then run the existing out-of-band
guarded `apply`. The transfer opt-in owns interface-specific LXC rules for TCP
22 and TCP 5201 alongside the existing SMB rule.

## 2. Prepare and pair each LXC

From each LXC console, use `findmnt` and the generated Samba mount facts to
review the available container paths. `lsblk` is supporting evidence only;
Proxmox bind mounts may not appear as ordinary LXC block devices.

Select an existing transfer root and an existing group with read, write, and
traverse access:

```bash
export PROXMOX_LXC_TRANSFER_ROOT=/OPERATOR/SELECTED/ROOT
export PROXMOX_LXC_TRANSFER_ACCESS_GROUP=EXISTING_STORAGE_GROUP
export PROXMOX_LXC_TRANSFER_USER=OPERATOR_SELECTED_AUTOMATION_USER

./setup/lxc/transfer.sh preflight
./setup/lxc/transfer.sh prepare
```

If the selected user already exists, its UID, GID, home, shell, and password
remain unchanged; it must already belong to the selected access group. If it
does not exist, the runner creates a locked restricted account in that group.
The dedicated DATA-Link SSH listener applies the same key-only forced-command
policy in either case.

When the LXC has default-deny outbound policy, use the existing
`setup/lxc/egress.sh` workflow to approve the published Pages and required
package endpoints for the installation window. Revoke those temporary rules
after both peers have applied and verified the transfer feature.

If discovery finds more than one directly connected static interface, select
the DATA-Link interactively or provide the displayed interface and CIDR. The
runner canonicalizes an address such as `HOST_ADDRESS/PREFIX` to the complete
network and refuses a peer-specific `/32` policy.

Exchange the generated public JSON bundles through a reviewed path. Apply the
other LXC's bundle on each side:

```bash
PROXMOX_LXC_TRANSFER_PEER_BUNDLE=/PATH/TO/PEER.json \
./setup/lxc/transfer.sh apply

./setup/lxc/transfer.sh verify
```

Private keys remain root-readable under `/etc/proxmox-transfer`. Applying a
bundle enrolls its client key and pins its server host key. Reapplying the
Samba feature preserves the active SSH and speed-test UFW rules.

## 3. Test the SSH pairing

On either LXC, enter the other LXC's DATA address:

```bash
proxmox-transfer-ssh check PEER_DATA_IPV4
```

A successful check prints `proxmox-transfer-ssh-ok`. It verifies the dedicated
client key, pinned server host key, enrolled public key, and restricted SSH
listener without opening a shell or reading or writing backup content. Repeat
in the opposite direction when bidirectional transfers are required.

## 4. Measure DATA-Link bandwidth

Choose the destination for this test and start its one-shot listener:

```bash
proxmox-transfer-speed-test server
```

From the selected source, enter the destination's DATA address:

```bash
proxmox-transfer-speed-test client PEER_DATA_IPV4
```

The client runs a basic 15-second, single-stream TCP test by default. Optional
`PROXMOX_LXC_TRANSFER_IPERF_SECONDS` and
`PROXMOX_LXC_TRANSFER_IPERF_STREAMS` values may adjust the run within the
helper's bounded limits. The server binds only to the saved DATA address and
exits after one client. Swap the two roles to measure the opposite direction.

## 5. Prepare an operator-selected destination

Before the first copy or a resumed copy, prepare the existing destination
directory from its Proxmox host. Rsync runs as the restricted transfer user,
so preserving directory times, modes, ACLs, and xattrs requires that identity
to own the destination root. The Samba presentation identity also receives
root and inheritable access before the copy starts.

```bash
export PROXMOX_LXC_STORAGE_PROFILE=transfer-destination
export PROXMOX_LXC_STORAGE_CTID=OPERATOR_SELECTED_CTID
export PROXMOX_LXC_STORAGE_CONTAINER_PATH=/OPERATOR/SELECTED/DESTINATION
export PROXMOX_LXC_STORAGE_SERVICE_USER=OPERATOR_SELECTED_SAMBA_SERVICE_USER
export PROXMOX_LXC_STORAGE_SERVICE_GROUP=OPERATOR_SELECTED_SAMBA_SERVICE_GROUP
export PROXMOX_LXC_STORAGE_TRANSFER_USER=OPERATOR_SELECTED_TRANSFER_USER

./setup/lxc/storage.sh preflight
./setup/lxc/storage.sh apply
./setup/lxc/storage.sh verify
```

The transfer-destination profile derives the bind source and mapped identities
from live Proxmox and LXC state. It changes ownership only on the selected
destination root and adds access/default ACLs only on that root; it does not
traverse or change descendants. It refuses active rsync processes, inactive
bind sources, symlinks, path escapes, nested filesystems, missing identities,
and stopped LXCs. It never mounts storage or restarts a container.

## 6. Copy operator-selected paths

The local path must exist within that LXC's selected transfer root. The path
after the colon is entered by the operator and is relative to the peer's
selected transfer root. No destination layout is assumed or generated.

```bash
# Send an operator-selected local path to an operator-entered peer path.
proxmox-transfer-rsync push /SELECTED/LOCAL/SOURCE/ \
  PEER_DATA_IPV4:SELECTED/DESTINATION/

# Or pull an operator-entered peer path into a selected local directory.
proxmox-transfer-rsync pull \
  PEER_DATA_IPV4:SELECTED/REMOTE/SOURCE/ /SELECTED/LOCAL/DESTINATION/
```

The helper copies files, directories, timestamps, modes, hard links, ACLs,
xattrs, and sparse files. It never enables rsync deletion or source-file
removal. Files present only at the destination remain in place. The forced
server command rejects the same destructive options even if an enrolled key
holder bypasses the helper and invokes rsync directly.

For a destination whose Samba and automation access ACLs must remain effective
during a long copy, select the ACL-safe backup mode. It preserves timestamps,
links, hard links, xattrs, and sparse files but deliberately does not restore
source POSIX modes or ACLs. Destination default ACLs remain authoritative.

```bash
proxmox-transfer-rsync backup-push /SELECTED/LOCAL/SOURCE/ \
  PEER_DATA_IPV4:SELECTED/DESTINATION/
```

For a detached, durable transfer with progress reporting, supply a unique job
name. The helper owns the Screen session, persistent log, PID, timestamps, and
exit status:

```bash
proxmox-transfer-rsync start-backup-push JOB_NAME \
  /SELECTED/LOCAL/SOURCE/ PEER_DATA_IPV4:SELECTED/DESTINATION/

proxmox-transfer-rsync status JOB_NAME
proxmox-transfer-rsync status JOB_NAME --output json
proxmox-transfer-rsync watch JOB_NAME
proxmox-transfer-rsync log JOB_NAME
proxmox-transfer-rsync list
```

`status` reports transferred bytes, whole-transfer percentage, rate, ETA,
elapsed time, transferred-file count, remaining checks, and a best-effort
current source file. A percentage is labelled provisional while rsync is still
discovering the incremental file list. `watch` refreshes every two seconds;
interrupting the viewer does not interrupt the background copy.

## 7. Optional verification

Verification is a separate operator-selected step after the copy. It performs
a checksum-enabled rsync dry run and reports differences without changing
either endpoint:

```bash
proxmox-transfer-rsync verify-push /SELECTED/LOCAL/SOURCE/ \
  PEER_DATA_IPV4:SELECTED/DESTINATION/

proxmox-transfer-rsync verify-pull \
  PEER_DATA_IPV4:SELECTED/REMOTE/SOURCE/ /SELECTED/LOCAL/DESTINATION/

proxmox-transfer-rsync verify-backup-push /SELECTED/LOCAL/SOURCE/ \
  PEER_DATA_IPV4:SELECTED/DESTINATION/
```

## 8. Reconcile authenticated Samba access

An rsync run that preserves source ACLs can replace inherited destination ACLs.
After the copy has finished, the Proxmox host can add the Samba presentation
identity back to one operator-selected destination subtree. The runner never
mounts or unmounts storage, changes persistent mount configuration, or restarts
the LXC. Its selected bind source must already be an active mountpoint.

Run on the destination Proxmox host with values from that deployment:

```bash
export PROXMOX_LXC_STORAGE_PROFILE=destination-reconciliation
export PROXMOX_LXC_STORAGE_CTID=OPERATOR_SELECTED_CTID
export PROXMOX_LXC_STORAGE_CONTAINER_PATH=/OPERATOR/SELECTED/DESTINATION
export PROXMOX_LXC_STORAGE_SERVICE_USER=OPERATOR_SELECTED_SAMBA_SERVICE_USER
export PROXMOX_LXC_STORAGE_SERVICE_GROUP=OPERATOR_SELECTED_SAMBA_SERVICE_GROUP
export PROXMOX_LXC_STORAGE_TRANSFER_USER=OPERATOR_SELECTED_TRANSFER_USER
# Optional private subtree below the selected destination:
export PROXMOX_LXC_STORAGE_EXCLUDE_CONTAINER_PATH=/OPERATOR/SELECTED/PRIVATE_SUBTREE

./setup/lxc/storage.sh preflight
./setup/lxc/storage.sh apply
./setup/lxc/storage.sh verify
```

The runner derives the bind source and host UID/GID mapping from live Proxmox
and LXC state. It grants additive access to the selected Samba identity,
transfer identity, and mapped container root while pruning the optional private
subtree. It refuses an inactive bind-source mountpoint, active rsync, symlinked
or escaping paths, nested filesystems, missing identities, and a stopped LXC.
`apply` adds read/write ACLs to regular files plus read/write/traverse and
inheritable ACLs to directories. It does not call `chown`, `chmod`, or any
rsync deletion operation. Re-run reconciliation after any later metadata-
preserving copy; ACL-safe backup mode does not restore source ACLs.

## Operations

```bash
./setup/lxc/transfer.sh verify
./setup/lxc/transfer.sh rotate

PROXMOX_LXC_TRANSFER_PEER_BUNDLE=/PATH/TO/BUNDLE.json \
./setup/lxc/transfer.sh revoke

PROXMOX_LXC_TRANSFER_CONFIRM_ROLLBACK=yes \
./setup/lxc/transfer.sh rollback
```

After key rotation, apply the replacement bundle wherever that key should be
accepted before revoking the old bundle. Rollback removes only feature-managed
runtime configuration and firewall rules; it does not remove transferred
content.
