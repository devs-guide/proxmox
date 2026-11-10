## 0.0.8-rc.1

This prerelease publishes the whole-GPU passthrough candidate together with the
PVE 9 AMDGPU recovery and temperature workflow. Operators can discover GPUs by
exact PCI identity, review host preparation, gate AMD passthrough on readable
native temperatures, and manage QEMU attachment and rollback through published
GitHub Pages entrypoints.

The candidate is intentionally not the final `0.0.8` release. GitHub Actions
validates the implementation and publication graph, and human PVE 9 testing
has confirmed readable temperatures after native AMDGPU restoration. The full
PVE 6.4/PVE 9 prepare, reboot, attach, guest-workload, detach, unprepare, and
host-restoration matrix remains a final-release gate.

### Scope

- Release range: `0.0.6..0.0.8-rc.1`
- Primary feature boundary: whole, node-local GPU passthrough for QEMU VMs
- Supported implementation lanes:
  - Proxmox VE 6.4 / Debian Buster
  - Proxmox VE 9.x / Debian Trixie
- PVE 9 AMD-native setup runner:
  `https://devs-guide.github.io/proxmox/setup.gpu.amd.sh`
- Temperature dispatcher:
  `https://devs-guide.github.io/proxmox/setup/temperature.sh`
- GPU inventory and passthrough runner:
  `https://devs-guide.github.io/proxmox/setup/vm/gpu.sh`
- Important exclusions: vGPU, SR-IOV, ACS override automation, guest-driver
  installation, ROM patching, automatic reset workarounds, and automatic host
  reboot
- `0.0.7` remains reserved for the separately planned ZFS-backed LXC and
  LAN-only Samba release.

### Highlights

- Discovers complete GPU slots and functions from live PCI/sysfs state and
  keeps exact BDF, driver, IOMMU, boot-display, NUMA, reset, and assignment
  evidence together.
- Adds transactional multi-GPU host preparation with immutable schema-v4 state,
  exact-BDF VFIO binding, verification, rollback, and display restoration.
- Adds a directly streamed PVE 9 AMDGPU runner that repairs the stock Proxmox
  kernel and `pve-firmware`, extracts specifically required AMD firmware when
  necessary, restores repository-managed passthrough state, and reports native
  temperatures without rebinding live VFIO devices.
- Adds a required AMD temperature gate that can temporarily resume a
  runtime-suspended device for sampling and then restore its power policy.
- Publishes and validates the complete runner dependency graph through GitHub
  Pages.

### Added

- `setup/vm/gpu.sh` with inventory, preflight, prepare, verify, attach, detach,
  status, and unprepare actions.
- Platform, inventory, inspection, and apply helpers under `cli/gpu/`.
- PVE 6.4 and PVE 9.x GPU release adapters plus the transactional Ansible GPU
  implementation.
- `setup.gpu.amd.sh` for PVE 9 native AMDGPU repair, verification, managed
  blacklisting, and managed unblacklisting through a streamed endpoint.
- `setup/temperature.sh` and its GPU helper for structured temperature evidence.
- Dedicated GPU, AMDGPU, temperature, runtime, and Pages contract validation.
- Operator runbooks for both PVE lanes and multi-AMD macOS acceptance.

### Changed

- GPU platform selection now follows discovered host facts; `--release` is an
  assertion rather than an override.
- Host preparation records every managed path and its rollback material instead
  of relying on a fixed file list.
- The AMDGPU setup flow accepts the bounded dynamic manifest produced by GPU
  preparation, archives restored state, and requires an operator-controlled
  reboot before final verification.
- Managed Ansible dispatch is canonicalized and reuses a compatible existing
  environment instead of rebuilding Python unnecessarily.
- Managed bootstrap accounts default to `username:username`; streamed runs can
  explicitly select the preserved or locked password policy.
- PVE LXC template discovery selects the latest available Debian template from
  `pveam` instead of relying on a stale fixed name.
- Feature publication is manifest-driven so CLI-only runners and inline empty
  dependency arrays are handled consistently.

### Fixed

- Corrected vendor selection, invalid blacklist-selector exit propagation,
  optional `vfio_virqfd` handling, and schema-set validation in the passthrough
  workflow.
- Corrected native AMDGPU restoration when selected devices were still owned by
  `vfio-pci` and the repository state covered a dynamic set of managed paths.
- Corrected temperature acquisition for runtime-suspended AMD GPUs while
  preserving the prior runtime-power policy.
- Added the missing publication and dependency validation needed for every GPU
  and temperature runtime artifact fetched from Pages.
- Improved CI failure reporting so remote Ansible, runtime, and Pages contract
  failures remain visible at the failing boundary.

### Operator workflow and safety

Read-only inventory and temperature operations may be streamed from Pages. The
PVE 9 AMDGPU runner also supports its documented setup, check, blacklist, and
unblacklist actions through `wget -qO- ... | sudo bash`; it never rebinds a live
VFIO device, changes VM configuration, or reboots automatically.

Mutating whole-VM passthrough actions remain review boundaries. The GPU runner
requires explicit selection, confirmation for display loss and reviewed
temperatures, stopped/local/non-HA VM state, complete IOMMU isolation, and
feature-owned rollback evidence. Host preparation and unpreparation report a
required reboot instead of performing one.

This RC has automated contract coverage and human evidence that a PVE 9 AMD
host can restore native ownership and return readable temperatures. It does not
claim final hardware acceptance for PVE 6.4 or for the complete guest
passthrough lifecycle.

### #COMMIT

`release:0.0.8-rc.1 - publish whole-gpu passthrough candidate`

### Notable commits since 0.0.6

- `b8b2bb6` — `feat: add reversible VM GPU passthrough runner`
- `33a91d3` — `refactor: dispatch GPU passthrough from discovered platform and inventory`
- `0c0eeb1` — `feat(vm): add transactional multi-GPU host preparation`
- `8a40c62` — `docs(release): require reviewed publication format`
- `b6e3afa` — `fix(runtime): avoid unnecessary Python source builds`
- `a691bf7` — `fix(lxc): select latest Debian templates from pveam`
- `1fb9ef1` — `feat(gpu): publish AMDGPU setup and temperature gate`
- `8bff847` — `docs(amdgpu): make Pages streaming the only interface`
- `ea28155` — `fix: restore native amdgpu from managed vfio state (#10)`
- `0f47e8e` — `fix: restore native amdgpu from dynamic state`
- `a3486fd` — `Merge pull request #11 from devs-guide/fix/amdgpu-state-temperature`

### Assets

- GitHub-generated source archives for tag `0.0.8-rc.1`
- Published Pages GPU, AMDGPU, temperature, Ansible, and runtime helper graph
- No additional binary artifacts
