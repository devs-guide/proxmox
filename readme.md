# devs-guide/proxmox

## Current Release

Release `0.0.7` adds an isolated ZFS-backed Samba ingest workflow to the
reviewed local ZFS provisioning delivered in `0.0.6`. It discovers and
preserves the Proxmox management path, builds a separate physical DATA-Link,
adds a static no-gateway LXC data interface, maps an accepted ZFS dataset into
an unprivileged container, and publishes one guest-read/authenticated-write
SMB3 share behind host and container firewall boundaries.

The published Proxmox VE 6.4/Buster and Proxmox VE 9.1/Trixie lanes remain
supported. Site-specific interfaces, bridges, addresses, CTIDs, storage paths,
share names, and credentials are discovered or confirmed rather than defaults.

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

See [the 0.0.7 release notes](RELEASE_NOTES.md),
[deployment runbook](docs/setup/lxc/ingest.md), and
[human acceptance record](docs/setup/lxc/human.acceptance.md) for the complete
scope and evidence. Whole-GPU passthrough remains planned for `0.0.8`, Local
Model Inventory for `0.0.9`, and proxy-backed egress is unnumbered future work.

## Release Publication

Every existing and future GitHub release page follows the
[release publication policy](docs/release/publication.md) and its
[review template](docs/release/template.md). The exact title and body require
human approval before publication or editing. Before a new release is
published, older release pages must be audited and reconciled with the same
structure without changing their tags, source commits, or assets.

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

Feature contributors and automation agents must follow the
[feature-authoring and parser-safety guide](docs/development/feature-authoring.md).
It defines the production-source-of-truth, regression-fixture, dependency,
GitHub Actions, and guarded Pages publication requirements.

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
- [SSH setup and key rotation](docs/cli/ssh/sync.md)
- [Archive inspection and rsync transfer](docs/cli/rsync/fetch.md)
- [Temporary restore storage](docs/cli/storage/temp.md)

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
