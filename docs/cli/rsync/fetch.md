# Archive inspection and rsync transfer

`cli/rsync/fetch.sh` inspects or transfers one regular QEMU `.vma` or
`.vma.zst` archive. It rejects symbolic links, LXC archives, arbitrary files,
and directory sources. The destination directory must already exist and must
not be a symbolic link.

The helper uses the dedicated identity documented in
[SSH setup and key rotation](../ssh/sync.md).
`jq` is required when `--output json` is selected and by the complete restore
runner's internal helper composition.

## Inspect a remote archive

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/rsync/fetch.sh |
  bash -s -- \
    --action inspect \
    --remote-host 10.0.0.10 \
    --remote-path /backup/vzdump-qemu-200-date.vma.zst \
    --output json
```

The JSON result contains a numeric source byte count and string SHA-256 and
basename values:

```json
{"bytes": 2147483648, "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "basename": "vzdump-qemu-200-date.vma.zst"}
```

Transfer output adds a string `path` property. Retain these values when
creating a managed staging filesystem.

## Transfer one archive

Use the storage helper to create `/mnt/pve-restore/201` before this command.
Do not create that path on the Proxmox root filesystem and transfer a large
archive into it unintentionally.

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/rsync/fetch.sh |
  bash -s -- \
    --action transfer \
    --remote-host 10.0.0.10 \
    --remote-path /backup/vzdump-qemu-200-date.vma.zst \
    --destination-dir /mnt/pve-restore/201 \
    --output path
```

The transfer uses `rsync --partial --append-verify` and can be rerun after an
interruption. Before succeeding, it confirms that the remote archive did not
change during transfer and that the local and remote byte counts and SHA-256
digests match.

Optional transfer controls include:

```text
--remote-user USER
--remote-port PORT
--identity PATH
--known-hosts PATH
--connect-timeout SECONDS
--rsync-timeout SECONDS
--rsync-bwlimit-kbps RATE
```

## Transfer an arbitrary directory manually

The published helper intentionally does not transfer folders. For a directory
that is not being treated as a VM archive, use raw `rsync`:

```bash
rsync \
  --archive \
  --partial \
  --append-verify \
  --secluded-args \
  --info=progress2 \
  --rsh="ssh -i /root/.ssh/proxmox-restore-ed25519 -p 22 -o ConnectTimeout=10 -o UserKnownHostsFile=/root/.ssh/known_hosts -o StrictHostKeyChecking=yes" \
  root@10.0.0.10:/source/folder/ \
  /destination/folder/
```

The trailing slash on `/source/folder/` copies its contents. Without that
trailing slash, `rsync` creates a nested `folder` directory at the destination.
Raw directory transfer does not create a restore manifest and is outside the
validated `qmrestore` workflow.
