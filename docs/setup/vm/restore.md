# Proxmox VM restore runbook

This runbook restores one remote QEMU VMA backup to a Proxmox VM. Run every
command on the destination Proxmox host as `root`. The source host stores the
backup and is reached over SSH.

All addresses, VM IDs, storage IDs, and paths below are examples. Replace them
for the current environment; none are embedded in the published scripts.

Related helper documentation:

- [SSH setup and key rotation](../../cli/ssh/sync.md)
- [Archive inspection and rsync transfer](../../cli/rsync/fetch.md)
- [Temporary restore storage](../../cli/storage/temp.md)

## Values used in the examples

| Value | Meaning |
| --- | --- |
| `10.0.0.10` | Remote source host containing the backup |
| `200` | Source VM ID encoded in the archive filename |
| `201` | Target VM ID to create on this Proxmox host |
| `local-lvm` | Temporary-stage and final target storage |
| `/backup/vzdump-qemu-200-date.vma.zst` | Absolute remote archive path |

The target VM ID should be unused. Replacing an existing VM requires the
explicit `--replace-existing` gate; the existing VM must be stopped, local to
the current node, and not HA-managed.

## 1. Set up or rotate the SSH key

For the first setup:

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh |
  bash -s -- \
    --action setup \
    --remote-host 10.0.0.10
```

To deliberately replace both sides of the dedicated pair:

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh |
  bash -s -- \
    --action setup \
    --remote-host 10.0.0.10 \
    --key-rotation \
    --yes
```

Confirm passwordless access before moving data:

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh |
  bash -s -- \
    --action check \
    --remote-host 10.0.0.10
```

## 2. Run the complete live restore

The `all` action performs preflight, remote inspection, temporary-stage
creation, resumable rsync transfer, byte and SHA-256 comparison, complete
zstd/VMA verification, capacity and VM-collision checks, `qmrestore`, and safe
stage cleanup:

```bash
wget -qO- https://devs-guide.github.io/proxmox/setup/vm/restore.sh |
  bash -s -- \
    --action all \
    --vm 201 \
    --source-vm 200 \
    --remote-host 10.0.0.10 \
    --remote-path /backup/vzdump-qemu-200-date.vma.zst \
    --stage-storage local-lvm \
    --target-storage local-lvm \
    --unique
```

The restored VM remains stopped by default. Add `--start` only when it should
start after successful restore verification and staging cleanup.

Run the same command with `--dry-run` first when reviewing a new host, storage
layout, or target VM choice.

## 3. Run each phase manually

Use these steps when observing or resuming each boundary separately.

### Inspect the remote file

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/rsync/fetch.sh |
  bash -s -- \
    --action inspect \
    --remote-host 10.0.0.10 \
    --remote-path /backup/vzdump-qemu-200-date.vma.zst \
    --output tsv
```

Record the returned byte count, SHA-256 digest, and basename.

### Create the temporary staging filesystem

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/storage/temp.sh |
  bash -s -- \
    --action create \
    --vm 201 \
    --source-vm 200 \
    --storage local-lvm \
    --source-bytes REPLACE_WITH_BYTES \
    --remote-host 10.0.0.10 \
    --remote-path /backup/vzdump-qemu-200-date.vma.zst \
    --remote-sha256 REPLACE_WITH_SHA256 \
    --archive-basename vzdump-qemu-200-date.vma.zst \
    --output path
```

The default output path for target VM `201` is `/mnt/pve-restore/201`.

### Transfer and verify the archive with rsync

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/rsync/fetch.sh |
  bash -s -- \
    --action transfer \
    --remote-host 10.0.0.10 \
    --remote-path /backup/vzdump-qemu-200-date.vma.zst \
    --destination-dir /mnt/pve-restore/201 \
    --output path
```

Rerun this command after an interruption. Partial data is retained and checked
before rsync appends to it.

### Verify and restore with qmrestore

```bash
wget -qO- https://devs-guide.github.io/proxmox/setup/vm/restore.sh |
  bash -s -- \
    --action restore \
    --vm 201 \
    --source-vm 200 \
    --archive /mnt/pve-restore/201/vzdump-qemu-200-date.vma.zst \
    --stage-storage local-lvm \
    --target-storage local-lvm \
    --unique
```

The restore action verifies the full archive before invoking `qmrestore`. On
success it validates the resulting VM configuration and target volumes, then
removes a manifest-owned staging LV. On failure it retains the verified stage
for diagnosis or resumption.

To retain the stage after success, add `--cleanup never`. Remove it later with
the documented storage-helper remove action.

## Raw directory transfer

The restore workflow accepts one `.vma` or `.vma.zst` archive, not a folder. If
an unrelated directory must be copied manually, use the raw command in
[Archive inspection and rsync transfer](../../cli/rsync/fetch.md#transfer-an-arbitrary-directory-manually).

Do not point an arbitrary folder transfer at `/mnt/pve-restore/<vm-id>` unless a
managed staging filesystem is mounted there and the files are intentionally
outside the automated restore contract.

## Operational safety

- Verify an SSH host fingerprint through a trusted channel before accepting it.
- Do not place passwords or private keys in command arguments.
- Do not use `--replace-existing`, `--capacity-override`, or `--yes` merely to
  bypass an unexplained safety refusal.
- `--unique` passes `--unique 1` to `qmrestore` to generate unique properties
  such as network-interface addresses for the restored VM.
- A transfer failure retains partial data for resume.
- An integrity or restore failure retains the staging archive.
- Automatic cleanup removes only a stage whose LV, filesystem, mount source,
  and manifest all match the requested target VM.
