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

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh | \
  bash -s -- --action setup --remote-host 10.0.0.11
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
