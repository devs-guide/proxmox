# Temporary restore storage

`cli/storage/temp.sh` creates a disposable ext4 filesystem on a thin LV in a
configured Proxmox `lvmthin` storage. The deterministic staging path is
`/mnt/pve-restore/<target-vm-id>` by default.

Use this helper instead of placing a large backup directly on the Proxmox root
filesystem. It applies thin-pool data and metadata thresholds and writes an
ownership manifest used for safe resume and cleanup.

The complete restore workflow uses `--output json` for storage composition and
therefore requires `jq` on the destination Proxmox host.

## Create or resume a stage

First inspect the remote archive with
[the rsync helper](../rsync/fetch.md) and copy its `bytes`, `sha256`, and
`basename` values into this command:

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

With `--stage-size auto`, the helper sizes the stage from the archive byte
count. An explicit size such as `--stage-size 500G` may be used instead, but the
source byte count is still useful manifest metadata.

If the deterministic staging LV already exists and its filesystem and manifest
match, the helper mounts and resumes it instead of recreating it.

## Check stage status

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/storage/temp.sh |
  bash -s -- \
    --action status \
    --vm 201 \
    --storage local-lvm \
    --output json
```

JSON status represents byte counts and utilization percentages as numbers;
storage, LV, device, mountpoint, and state fields are strings.

```json
{"state":"absent","storage":"local-lvm","vg":"pve","thin_pool":"data","lv":"restore_stage_vm201","device":"/dev/pve/restore_stage_vm201","mountpoint":"/mnt/pve-restore/201","stage_bytes":0,"pool_size_bytes":107374182400,"data_percent":12.5,"metadata_percent":1.25,"vg_free_bytes":53687091200}
```

## Remove a manifest-owned stage

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/storage/temp.sh |
  bash -s -- \
    --action remove \
    --vm 201 \
    --storage local-lvm
```

Removal validates the LV, filesystem, mount source, and ownership manifest
before unmounting and deleting the LV. Do not manually delete the manifest.
The end-to-end restore runner performs this cleanup automatically after a
successful restore unless `--cleanup never` is selected.
