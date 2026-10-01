# Human ZFS acceptance procedure

Run this procedure from a root shell on the target Proxmox host. Discovery,
configuration, validation, and planning are safe review stages. Stop before
`wipe-signatures` or `apply` unless a human has separately approved that exact
destructive action and plan ID.

Disk health is advisory by default. A SMART result of `failed` or `unknown` is
shown prominently but does not, by itself, make an otherwise-safe disk
ineligible. Mounted filesystems, swap, LVM, mdraid, Ceph, ZFS membership,
holders, non-whole disks, missing stable identity, and unapproved signatures
remain hard blockers.

## 1. Download the reviewed runner

```bash
umask 077
mkdir -p /root/zfs-0.0.6-acceptance
cd /root/zfs-0.0.6-acceptance

wget -qO ./zfs.sh https://devs-guide.github.io/proxmox/setup/storage/zfs.sh
chmod 0700 ./zfs.sh
./zfs.sh --help
```

Planning and destructive actions require this downloaded regular file. Do not
stream those actions into Bash.

## 2. Collect and review inventory

No health-policy or evidence options are needed for the normal workflow:

```bash
./zfs.sh inventory \
  --install-deps \
  --output json \
  --output-file ./inventory.json

jq . ./inventory.json | less
```

Confirm all of the following:

- System and boot devices are excluded.
- Intended pool members are whole disks with unique stable
  `/dev/disk/by-id/...` paths, WWNs, and serials.
- Model, transport, exact byte size, logical sector size, and physical sector
  size agree with the physical labels and controller inventory.
- No intended disk reports a mounted filesystem, swap, LVM, mdraid, Ceph,
  imported ZFS membership, holders, or an unexpected signature.
- SMART warnings are reviewed as advisory information alongside the
  operator's prior burn-in records.
- The reported HBA, enclosure, slot, and fault-domain information is plausible.

Stop if identity, current usage, or signature results are unexpected.

## 3. Generate the proposed configuration

Use model and hardware filters to obtain a short candidate list, then answer
`y` or `n` for each displayed disk:

```bash
./zfs.sh configure \
  --type sas \
  --media hdd \
  --size 6TB \
  --model ST6000NM0034 \
  --pool archive \
  --vdev-type raidz2 \
  --vdev-count 2 \
  --dataset archive/samba \
  --mountpoint /media/archive
```

At the prompts:

- Use `y` or `n` to review disks individually.
- Use `none` to stop selection.
- Use `all` only after every remaining displayed disk has been positively
  identified.
- Review the device order before typing `WRITE`.

For a deterministic, already-reviewed selection, pass one ordered serial array:

```bash
./zfs.sh configure \
  --type sas \
  --media hdd \
  --size 6TB \
  --model ST6000NM0034 \
  --serial='[SERIAL_01,SERIAL_02,SERIAL_03,SERIAL_04]' \
  --non-interactive \
  --pool archive \
  --vdev-type raidz2 \
  --vdev-count 1 \
  --dataset archive/samba \
  --mountpoint /media/archive
```

For a longer list, put one serial on each line in the desired order (blank
lines and lines beginning with `#` are ignored), then use:

```bash
./zfs.sh configure \
  --type sas \
  --model ST6000NM0034 \
  --serial ./archive.serials.txt \
  --non-interactive \
  --pool archive \
  --vdev-type raidz2 \
  --vdev-count 2 \
  --dataset archive/samba \
  --mountpoint /media/archive
```

Set the requested vdev count for the real topology. Do not use `--all-matches`
merely to avoid reviewing the inventory.

The command writes `./zpool.config` with mode `0600`. It does not create or
modify a pool.

## 4. Manually review `zpool.config`

```bash
jq . ./zpool.config | less

jq -r '
  .vdevs[] |
  "\(.name) \(.type)",
  (.devices[] |
    "  \(.label) \(.path) serial=\(.expected_serial) wwn=\(.expected_wwn) bytes=\(.expected_size_bytes) domain=\(.observed_fault_domain)")
' ./zpool.config
```

Confirm:

- Pool, dataset, mountpoint, vdev type, vdev count, and vdev width are correct.
- Every stable path, WWN, serial, byte size, transport, and sector size matches
  the approved inventory.
- No device occurs twice.
- `ashift=12`, `compression=lz4`, `atime=off`, `xattr=sa`,
  `acltype=posixacl`, `recordsize=1M`, and `dedup=off` are appropriate.
- `allow_signature_wipe` remains `false` unless a separate wipe has been
  explicitly approved.
- A `single-hba` advisory, if present, has been reviewed against the actual
  HBA, expander, backplane, enclosure, and power layout. Logical ordering is
  not fault-domain isolation.

Edit the JSON before continuing if grouping or properties need adjustment.

## 5. Validate against current hardware

Run these immediately before planning:

```bash
./zfs.sh validate-config --config ./zpool.config
./zfs.sh preflight --config ./zpool.config
```

Both must pass. Stop on identity, byte-size, sector-size, transport, active
usage, signature, existing-pool, or importable-pool drift. An advisory SMART
warning alone is not a preflight failure under the default policy.

## 6. Generate and review the immutable plan

```bash
./zfs.sh plan \
  --config ./zpool.config \
  --plan-file ./zpool.plan

jq . ./zpool.plan | less
jq -r '.plan_id' ./zpool.plan
sha256sum ./zpool.config ./zpool.plan
```

Record and review the configuration checksum, plan ID, complete device list,
topology, estimated capacity, and exact proposed `zpool create` and `zfs
create` commands. Confirm that no unexpected property or vdev is present and
that the create command does not contain `-f`.

Stop here for candidate testing. Reaching a reviewed create plan is sufficient
to validate the published tooling without changing any disk.

## 7. Optional health policies

The default `advisory` policy requires no extra flags or log files. Operators
who intentionally want live SMART to block selection may add:

```bash
--health-policy smart-required
```

Previously generated BHT evidence can also be attached for display without
making it a blocker:

```bash
--health-evidence /path/to/bht-drive-reference.latest.json \
--evidence-server SERVER_NAME
```

Only use the following when BHT evidence is deliberately required for every
selected disk:

```bash
--health-policy bht-required \
--health-evidence /path/to/bht-drive-reference.latest.json \
--evidence-server SERVER_NAME
```

`--health-evidence-root DIRECTORY` additionally verifies each referenced
evidence package's `SHA256SUMS`. It is optional. Evidence matching uses serial
and normalized model, not historical `/dev/sdX` names. When evidence is part of
the reviewed configuration, supply the same evidence options to `preflight`,
`plan`, and any later plan revalidation.

## 8. Separately authorized destructive branch

If signatures are detected, ordinary creation remains blocked. A separately
approved wipe requires `allow_signature_wipe: true`, a fresh signature-wipe
plan, its exact plan ID, `--mode wipe-signatures`, the exact pool name, and
interactive confirmation for each path. After wiping, discard that plan and
repeat inventory, validation, preflight, and planning.

Pool creation likewise requires explicit human authorization that records the
exact plan ID, topology, and stable paths. Only then may the operator run:

```bash
./zfs.sh apply \
  --plan-file ./zpool.plan \
  --plan-id EXACT_PLAN_ID \
  --mode create \
  --confirm-create archive
```

Do not add `--yes` during human acceptance.

## 9. Post-creation verification

After an independently authorized creation:

```bash
./zfs.sh status --pool archive --output text
./zfs.sh verify --config ./zpool.config
zpool status -P archive
zpool list archive
zfs list -r archive
findmnt /media/archive
```

Preserve `inventory.json`, `zpool.config`, `zpool.plan`, checksums, plan ID, and
verification output as private acceptance evidence. Samba and LXC setup begin
only after ZFS acceptance is signed off.
