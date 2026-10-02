# devs-guide/proxmox

## Current Release

Release `0.0.6` adds reviewed general local ZFS provisioning to the managed
Proxmox runtime, networking, LXC, and VM restore baseline released in `0.0.5`.
The published Proxmox VE 6.4/Buster and Proxmox VE 9.1/Trixie lanes remain
supported.

```bash
# Proxmox VE 6.4 / Debian Buster
wget -qO- https://devs-guide.github.io/proxmox/6.4.sh | bash

# Proxmox VE 9.1 / Debian Trixie
wget -qO- https://devs-guide.github.io/proxmox/9.1.sh | bash
```

The shared examples are LAN-oriented and operator-managed. Baseline account
passwords default to their account names (`app`, `agent`, `proxmox`, and
`root`), the default allowed subnet is `10.0.0.0/24`, and the PVE 9.1 lane uses
the Proxmox no-subscription repository. Update these values for the target
environment before treating the setup as final.

See [the 0.0.6 release notes](RELEASE_NOTES.md) for the complete scope and
acceptance evidence. ZFS-backed LXC/Samba delivery is planned for `0.0.7`,
whole-GPU passthrough for `0.0.8`, and Local Model Inventory for `0.0.9`.

## ZFS Provisioning

The 0.0.6 feature discovers local disks and writes an editable
`./zpool.config`. It does not create a pool during discovery or configuration.
Its storage-oriented defaults are pool `zfspool`, dataset `zfspool/archive`,
and mountpoint `/media/zfspool/archive`; Samba and LXC remain later consumers
of that dataset rather than part of its name. Interactive disk review is
pretty-printed JSON by default.

```bash
mkdir -p /root/zfs-setup
cd /root/zfs-setup
wget -qO- https://devs-guide.github.io/proxmox/setup/storage/zfs.sh | \
  bash -s -- --type sas --size 6TB
```

Download the runner before generating or applying a destructive plan. Review
the design in [the ZFS feature plan](docs/setup/storage/zfs/feature.plan) and
follow [the human acceptance procedure](docs/setup/storage/zfs/human.acceptance.md)
for review, planning, explicitly authorized creation, and verification.

## Feature Runner Naming

- Proxmox-native feature runners keep their existing `setup/...` layout such as `setup/vlan.sh` and publish aliases such as `setup.vlan.sh`.
- Non-Proxmox CLI application installers for Proxmox hosts should use the `cli.{app_name}` naming family.

Current convention:

- source runner: `setup/cli.{app_name}.sh`
- published runner: `setup.cli.{app_name}.sh`
- Debian-side playbook when needed: `ansible/debian/cli.{app_name}.yml`

Current example:

```bash
wget -qO- https://devs-guide.github.io/proxmox/setup.cli.codex.sh | bash
```

## VM Restore Helpers

Every published Bash helper uses a `.sh` path and can bootstrap its shared
library when streamed directly into Bash.
Structured helper output uses `--output json` and requires `jq`.

Human operator documentation:

- [End-to-end and manual VM restore runbook](docs/setup/vm/restore.md)
- [Whole-GPU passthrough test runbook](docs/setup/vm/gpu/manual.md)
- [PVE 6.4 / Buster GPU passthrough runbook](docs/setup/vm/gpu/pve-6.4.md)
- [PVE 9.1 / Trixie GPU passthrough runbook](docs/setup/vm/gpu/pve-9.1.md)
- [Manual GPU passthrough acceptance examples](docs/setup/vm/gpu/examples.md)
- [PVE 9 multi-AMD macOS acceptance runbook and evidence](docs/setup/vm/gpu/pve9-multi-amd-macos-acceptance.md)
- [Whole-GPU passthrough implementation plan](docs/setup/vm/gpu/master.plan)
- [SSH setup and key rotation](docs/cli/ssh/sync.md)
- [Archive inspection and rsync transfer](docs/cli/rsync/fetch.md)
- [Temporary restore storage](docs/cli/storage/temp.md)

GPU platform and PCI identities are always discovered live. Stream only the
read-only inventory action; download and inspect the runner before a dry-run or
mutation:

```bash
wget -qO- https://devs-guide.github.io/proxmox/setup/vm/gpu.sh | \
  bash -s -- --action inventory --output json
```

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh | \
  bash -s -- --action setup --remote-host 10.0.0.11
```

Rotate the dedicated key only after the fresh key is installed and verified:

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh | \
  bash -s -- --action setup --remote-host 10.0.0.11 \
    --key-rotation --yes
```

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/storage/temp.sh | \
  bash -s -- --action status --vm 200
```

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/rsync/fetch.sh | \
  bash -s -- --action inspect --remote-host 10.0.0.11 \
    --remote-path /backup/vzdump-qemu-200-date.vma.zst
```
