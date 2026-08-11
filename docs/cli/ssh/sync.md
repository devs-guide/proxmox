# SSH setup and key rotation

The VM restore helpers use a dedicated ED25519 identity instead of a user's
default SSH key. Run these commands on the Proxmox host that will receive and
restore the backup. The remote host is the system holding the backup archive.

All addresses in this document are examples. The helper receives the address
at runtime and does not embed it in the script. OpenSSH records the accepted
host key in `/root/.ssh/known_hosts`, which is expected.

## Initial setup

Verify the remote host fingerprint through a trusted channel before accepting
it at the prompt. Then install the dedicated key:

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh |
  bash -s -- \
    --action setup \
    --remote-host 10.0.0.10
```

The command creates these files by default:

- `/root/.ssh/proxmox-restore-ed25519`
- `/root/.ssh/proxmox-restore-ed25519.pub`
- `/root/.ssh/known_hosts`

It installs only the dedicated public key. A remote password prompt is normal
during the initial `ssh-copy-id` operation.

When the expected SSH host-key fingerprint is known, pin it during setup:

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh |
  bash -s -- \
    --action setup \
    --remote-host 10.0.0.10 \
    --host-key-fingerprint SHA256:REPLACE_WITH_VERIFIED_FINGERPRINT
```

Never copy a password into a command-line flag. The helper intentionally lets
`ssh-copy-id` request it interactively.

## Check passwordless access

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh |
  bash -s -- \
    --action check \
    --remote-host 10.0.0.10
```

A successful check exits with status zero after logging a BatchMode SSH check.

## Rotate the dedicated key manually

Use `--key-rotation --yes` when the existing dedicated pair is stale,
mismatched, or should be replaced routinely:

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh |
  bash -s -- \
    --action setup \
    --remote-host 10.0.0.10 \
    --key-rotation \
    --yes
```

The rotation order is deliberate:

1. Generate a fresh temporary ED25519 pair.
2. Install only its public key on the remote host.
3. Verify BatchMode access with the temporary private key.
4. Atomically replace the local dedicated pair.
5. Verify BatchMode access again at the permanent path.
6. Remove only public-key blobs matching the previous dedicated key material
   from the remote `authorized_keys` file.
7. Delete the saved old local pair.

If installation or the first verification fails, the current local pair is not
replaced and temporary key files are removed. A repeated BatchMode check during
a successful rotation is expected: one check protects the swap and the second
protects removal of the old key.

To preview the mutations without changing keys, add `--dry-run` while retaining
the required `--key-rotation --yes` flags.

## Non-default connection values

Pass connection settings explicitly when the remote user, port, identity, or
known-hosts path differs from the defaults:

```bash
wget -qO- https://devs-guide.github.io/proxmox/cli/ssh/sync.sh |
  bash -s -- \
    --action check \
    --remote-host backup.example.net \
    --remote-user root \
    --remote-port 2222 \
    --identity /root/.ssh/proxmox-restore-ed25519 \
    --known-hosts /root/.ssh/known_hosts
```

Do not bypass a host-key-changed warning. Confirm the new fingerprint through a
trusted channel before updating `known_hosts`.
