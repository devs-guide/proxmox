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
