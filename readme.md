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
