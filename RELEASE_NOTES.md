# 0.0.6 - General Local ZFS Provisioning

Release `0.0.6` adds an opt-in, host-local ZFS workflow to the Proxmox toolkit.
It discovers disks, writes an operator-editable configuration, validates that
declaration against current hardware, generates an immutable reviewed plan,
creates only after explicit authorization, and verifies the resulting pool and
datasets.

The feature is general. It does not depend on a hostname, IP address, fixed
disk count, transport, pool name, dataset name, mountpoint, or chassis layout.
Samba, LXC, networking, GPU passthrough, and model inventory are outside this
release.

## Scope

- Release range: `0.0.5..0.0.6`
- Supported host lanes remain:
  - Proxmox VE 6.4 / Debian Buster
  - Proxmox VE 9.1 / Debian Trixie
- New published feature entrypoint:
  - `setup/storage/zfs.sh`
- New published configuration helper:
  - `setup/storage/zpool.config.sh`
- New reviewed implementation helper:
  - `cli/storage/zfs.pool.sh`

Release `0.0.5` remains the baseline for managed Proxmox runtime, networking,
LXC, and VM restore behavior. This release adds the separately invoked storage
workflow without changing the automatic bootstrap playlists.

## Highlights

- Uses native Debian/Linux, smartmontools, LVM, mdraid, and OpenZFS tooling to
  inventory local disks and active-use hazards.
- Records stable by-id path, WWN, serial, exact bytes, transport, sector sizes,
  health context, signatures, HBA, SCSI HCTL, and slot-derived evidence.
- Presents pretty-printed JSON for candidate, exclusion, and ordered-device
  review before writing `zpool.config`.
- Supports repeatable model filters and ordered serial selection through a
  bracketed list or one-serial-per-line text file.
- Treats `6TB` as decimal and `5.5TiB` as binary while rejecting ambiguous
  size syntax such as `5.5T`.
- Supports equal-width mirror, RAIDZ1, RAIDZ2, and RAIDZ3 data vdevs.
- Orders by unique numeric slot evidence when available and refuses ambiguous
  automatic ordering instead of silently grouping by transient disk names.
- Keeps SMART and optional BHT evidence advisory unless the operator selects a
  stricter health policy.
- Separates signature wiping from creation and never adds `zpool create -f`.
- Generates an immutable plan ID with exact commands, capacity estimates,
  topology, and a `zpool create -n` dry run.
- Verifies data-vdev topology, membership, properties, datasets, and mounts
  after creation.

## Configuration and review

The interactive configuration flow filters eligible disks, asks the operator
to confirm each candidate with `y`, `n`, `all`, or `none`, displays selected
order, and writes mode-`0600` JSON in the current working directory. Operators
may edit grouping, properties, datasets, and mountpoints before validation.

Generated defaults use pool `zfspool`, dataset `zfspool/archive`, and
mountpoint `/media/zfspool/archive`. These names describe storage rather than a
future consumer. Every value can be overridden.

The schema records exact identity and size expectations for each selected
device. Validation and preflight reject duplicate paths, non-whole-disk input,
identity or sector drift, unsafe active usage, unexpected signatures, and an
existing or importable pool with the requested name.

## Whole-disk behavior

The reviewed input is a complete disk through a stable
`/dev/disk/by-id/...` path without a partition suffix. OpenZFS owns the Linux
GPT and aligned ZFS-member layout; operators should not manually partition
selected devices. Configuration, validation, preflight, and planning do not
write disks. `apply` is the destructive boundary, but it is not a full-device
overwrite or secure erase and does not invoke `zpool initialize`.

After OpenZFS creation, Linux may display the main ZFS member as partition 1
and a small reserved partition 9. That uniform layout is expected. Changing
partitions or signatures after planning invalidates the reviewed plan.

## Property compatibility

Generated configurations use OpenZFS's canonical `acltype=posix` value.
Previously reviewed configurations containing the accepted `posixacl` alias
remain valid: verification normalizes both representations to `posix` while
continuing to reject `off`, `nfsv4`, and other mismatches.

The storage defaults include `ashift=12`, `autotrim=off`, `compression=lz4`,
`atime=off`, `xattr=sa`, `dnodesize=auto`, an unmounted pool root, and a
mounted dataset with `recordsize=1M` and `dedup=off`.

## Human acceptance

The accepted deployment created an ONLINE pool from 18 reviewed SAS HDDs as
two nine-member RAIDZ2 data vdevs. Members were grouped by observed slots 0–8
and 9–17 and referenced through stable WWN paths. OpenZFS produced a uniform
GPT/ZFS layout on all selected disks, the archive dataset mounted at its
declared path, and the pool reported no known data errors.

This topology is evidence, not a product default. The observed single-HBA
condition remains a documented physical-topology advisory. Numeric ordering
improves serviceability but does not prove expander, backplane, or power-domain
isolation.

## Safety boundaries

- Planning and destructive actions require a downloaded regular script; they
  are refused from a streamed shell.
- Creation requires the reviewed plan file, its SHA-256 plan ID, mode
  `create`, the exact pool name, and a final confirmation.
- Signature wiping requires its own plan, mode, pool confirmation, and device
  review. A wipe plan cannot be reused for creation.
- Health is advisory by default; stricter SMART or BHT enforcement is
  explicitly operator-selected.
- No pool is automatically destroyed, exported, recreated, or initialized.
- Private configuration, plan, checksum, and verification evidence remains
  operator-owned.

## Deferred work

- `0.0.7`: ZFS-backed Debian LXC creation, split management/egress/data
  networking, mapped dataset permissions, and LAN-restricted Samba.
- `0.0.8`: whole-GPU passthrough inventory, preparation, attachment,
  verification, and rollback.
- `0.0.9`: Local Model Inventory.

## Release artifacts

- GitHub-generated source archives for tag `0.0.6`
- Published Pages ZFS runner and helper graph, with design and acceptance
  documentation in the source release
- No additional binary assets
