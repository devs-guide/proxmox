# devs-guide/proxmox

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
