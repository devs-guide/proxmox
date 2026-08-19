# Proxmox VE 9 GPU / PCIe Passthrough Master Plan

> Research reference retained for review provenance. The current implementation
> plan is `master.plan`; use `manual.md` for supported commands and safety gates.

Operator runbooks:

- [Shared action and state contract](manual.md)
- [PVE 6.4 / Buster GPU passthrough](pve-6.4.md)
- [PVE 9.1 / Trixie GPU passthrough](pve-9.1.md)
- [Command examples](examples.md)

**Review date:** August 15, 2026
**Primary target:** Proxmox VE 9.x on x86-64
**Current release baseline:** PVE 9.2; Linux 7.0 is the current stable default kernel
**Also applicable to:** PVE 9 systems still running 6.14 or 6.17
**Purpose:** Dedicated PCIe GPU passthrough to Windows, Linux, or an existing OpenCore-based macOS VM
**Important:** This is a decision-oriented review document, not one script to paste from beginning to end.

The following branches are mutually exclusive in places:

- Choose the Intel or AMD host-IOMMU path.
- Choose the actual host bootloader path.
- Start with automatic Proxmox device handoff.
- Use early VFIO binding only if automatic handoff fails.
- Use global driver blacklisting only if early binding is insufficient.
- Use ACS override, unsafe interrupts, `ignore_msrs`, ROM files, or `vendor-reset` only for a demonstrated problem.
- Replace every placeholder before running a command.

---

# 1. Corrections to the previous guide

| Previous instruction | Proxmox VE 9 correction |
|---|---|
| Install `cpu-checker` and use `kvm-ok` | Not required for PCIe passthrough on a functioning PVE host. Verify `/dev/kvm`, CPU flags, IOMMU logs, and IOMMU groups directly. |
| Install `pve-headers-$(uname -r)` | Ordinary VFIO passthrough requires no headers. For DKMS only, PVE 9 uses `proxmox-headers-$(uname -r)` and optionally `proxmox-default-headers`. |
| Add `amd_iommu=on` | Invalid Linux AMD-IOMMU value and ignored. Modern AMD systems enable the hardware IOMMU when firmware exposes it. |
| Always add `intel_iommu=on` | PVE 9 kernels are new enough that IOMMU is normally enabled by default when VT-d is enabled. Verify first. `intel_iommu=on` remains a valid Intel fallback. |
| Use `iommu=soft` after AMD errors | Incorrect for VFIO. `iommu=soft` selects software bounce buffering and is not a hardware-IOMMU passthrough solution. |
| Load `vfio_virqfd` | Removed as a separate module beginning with Linux 6.2. Its functionality is integrated into VFIO. |
| Always blacklist AMD or NVIDIA host drivers | Do not do this initially. Current Proxmox attempts automatic unbind/VFIO handoff. |
| Always bind IDs in `vfio.conf` | Use only if automatic handoff fails. ID binding affects every installed device with the same vendor/device ID. |
| Always enable unsafe interrupts | Do not. It weakens isolation and may reduce stability. Use only for a precise interrupt-remapping failure on hardware that cannot be fixed. |
| Always add `options kvm ignore_msrs=1` | Do not. This is primarily a conditional macOS/OpenCore workaround or targeted diagnostic. |
| Always use ACS override | Do not. It creates synthetic groups without creating real hardware isolation. |
| Demand `vfio-pci` before VM start | Only when using persistent early binding. With automatic handoff, the native host driver may be present while the VM is off; `vfio-pci` must own the device while the VM is running. |
| Assume GPU has only graphics and audio | Modern cards may expose graphics, audio, USB, UCSI, or other PCI functions. Inventory every function. |
| Always disable VM autostart | Disable only during commissioning. It may be re-enabled after repeatable start/stop testing. |
| Use `shutdown -s -t 0` in Windows | Correct syntax is `shutdown /s /t 0`. |
| Add fixed hugepage settings | Hugepages are optional performance tuning, not a passthrough requirement or reset fix. |

Sources: [S2], [S5], [S6], [S7], [S8], [S9], [S10]

---

# 2. Preconditions and safety boundaries

Before changing the host:

1. Have working SSH access from another system.
2. Preferably have iDRAC, iLO, IPMI, BMC KVM, or physical console access.
3. Do not pass through:
   - The controller containing the PVE boot disk.
   - The only management NIC.
   - A PCIe bridge containing indispensable host devices.
4. Make the BMC GPU, an iGPU, or a second dedicated host GPU the firmware primary display.
5. Do not use the passthrough GPU for:
   - The PVE console.
   - Xorg or Wayland.
   - Host CUDA/ROCm applications.
   - Host transcoding.
   - An LXC container.
   - Another VM.
6. Fully stop the target VM before changing its machine type, firmware, or PCI configuration.
7. Do not combine a PVE upgrade, firmware update, kernel change, and VFIO reconfiguration in one troubleshooting event.
8. Keep at least one known-good Proxmox kernel available in the boot menu.

---

# 3. Define the host-specific values

Use domain-qualified addresses for Linux inspection. Proxmox VM configuration normally uses the address without the `0000:` domain.

Example only:

```bash
VMID=200

# Linux/sysfs form:
GPU_SLOT="0000:65:00"
GPU_BDF="0000:65:00.0"
AUDIO_BDF="0000:65:00.1"

# Proxmox qm form:
GPU_SLOT_QM="65:00"
GPU_BDF_QM="65:00.0"
AUDIO_BDF_QM="65:00.1"
```

Do not assume `.1` is the only additional function. Some GPUs also expose:

```text
65:00.0  VGA or 3D controller
65:00.1  HDMI/DisplayPort audio
65:00.2  USB controller
65:00.3  USB Type-C/UCSI controller
```

---

# 4. Capture the existing host state and configuration

Record the exact PVE, kernel, bootloader, Secure Boot, PCI, and VM configuration before making changes.

```bash
pveversion -v
uname -a
uname -r
cat /etc/os-release
cat /proc/cmdline

proxmox-boot-tool status || true
proxmox-boot-tool kernel list || true

if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state
fi

qm status "$VMID"
qm config "$VMID"
```

Create a dated backup directory:

```bash
STAMP="$(date +%F-%H%M%S)"
BACKUP="/root/pve9-passthrough-${VMID}-${STAMP}"

install -d -m 0700 "$BACKUP"

pveversion -v > "$BACKUP/pveversion.txt"
uname -a > "$BACKUP/uname.txt"
cat /proc/cmdline > "$BACKUP/proc-cmdline.txt"
proxmox-boot-tool status > "$BACKUP/proxmox-boot-tool-status.txt" 2>&1 || true
proxmox-boot-tool kernel list > "$BACKUP/kernel-list.txt" 2>&1 || true
qm config "$VMID" > "$BACKUP/qm-${VMID}.conf"

for FILE in \
    /etc/default/grub \
    /etc/kernel/cmdline \
    /etc/modules \
    /etc/initramfs-tools/modules
do
    if [ -e "$FILE" ]; then
        cp -a "$FILE" "$BACKUP/"
    fi
done

cp -a /etc/modprobe.d "$BACKUP/modprobe.d"
```

During commissioning, disable automatic VM startup:

```bash
qm set "$VMID" -onboot 0
```

---

# 5. Enable virtualization and IOMMU in system firmware

## Intel host

Enable the firmware settings corresponding to:

```text
Intel Virtualization Technology / VT-x
Intel VT-d
IOMMU
DMA Remapping
Interrupt Remapping
```

## AMD host

Enable the firmware settings corresponding to:

```text
SVM / AMD-V
IOMMU / AMD-Vi
IOMMU Pre-boot Behavior, where applicable
```

## Additional firmware considerations

For a multi-GPU server or a GPU with large PCI BARs, enable:

```text
Above 4G Decoding
64-bit PCIe MMIO
```

Treat Resizable BAR separately:

```text
Resizable BAR is not required for VFIO.
Start with the firmware default.
If BAR allocation or guest compatibility problems appear, test with ReBAR disabled.
For macOS/OpenCore passthrough, start with ReBAR disabled unless the exact
OpenCore and GPU configuration explicitly supports it.
```

Set the host's primary display to:

```text
BMC / onboard VGA / iGPU / another non-passthrough GPU
```

Do not make the target passthrough card the primary display unless single-GPU passthrough is intentional and the additional boot-framebuffer complications are understood.

---

# 6. Verify CPU virtualization and IOMMU before changing kernel arguments

PVE itself normally confirms KVM capability by running VMs. These direct checks replace the old `cpu-checker` prerequisite.

```bash
grep -m1 -oE 'vmx|svm' /proc/cpuinfo
test -e /dev/kvm && echo "/dev/kvm is present"

lsmod | grep -E '^kvm|kvm_'
```

Check kernel initialization:

```bash
journalctl -b -k | grep -Ei \
    'DMAR|AMD-Vi|IOMMU|interrupt remapping|remapping enabled'
```

Count assigned IOMMU-group devices:

```bash
find /sys/kernel/iommu_groups -type l 2>/dev/null | wc -l
```

List the groups:

```bash
for DEV in /sys/kernel/iommu_groups/*/devices/*; do
    [ -e "$DEV" ] || continue

    GROUP="${DEV#*/iommu_groups/}"
    GROUP="${GROUP%%/*}"

    printf 'IOMMU group %-4s ' "$GROUP"
    lspci -Dnn -s "${DEV##*/}"
done | sort -V
```

## PVE 9 decision

If multiple sensible IOMMU groups already exist:

```text
Do not add an IOMMU enable argument merely because an older guide says to.
Continue to PCI inventory and group validation.
```

PVE 9 kernels are new enough that both Intel and AMD IOMMUs are normally enabled when the required firmware setting and hardware tables are present.

If there are no groups:

```text
1. Recheck VT-d/IOMMU in firmware.
2. Confirm that the motherboard firmware is current.
3. Confirm that both CPU and chipset support IOMMU.
4. Only then use the appropriate kernel-argument fallback below.
```

Sources: [S2], [S5], [S6], [S7]

---

# 7. Add kernel arguments only when actually required

## 7.1 Valid PVE 9 arguments

### Intel fallback

If VT-d is enabled but the Intel IOMMU still does not initialize:

```text
intel_iommu=on
```

Optional passthrough-domain mode:

```text
iommu=pt
```

Example combination:

```text
intel_iommu=on iommu=pt
```

`iommu=pt` does not enable an absent IOMMU. It changes the default DMA-domain behavior for host devices.

### AMD normal path

For a normal AMD system:

```text
No amd_iommu enable parameter should be required.
```

Optional passthrough-domain mode:

```text
iommu=pt
```

Do not use:

```text
amd_iommu=on
```

`on` is not a valid value for the Linux `amd_iommu=` parameter.

The Linux kernel does provide:

```text
amd_iommu=force_enable
```

but it is an exceptional workaround for platforms the kernel considers buggy. The kernel documentation explicitly says to use it with care. It is not the normal AMD passthrough setting and does not replace a missing firmware IOMMU table.

### Invalid VFIO fallback

Do not use:

```text
iommu=soft
```

That selects software I/O translation through SWIOTLB rather than providing the hardware isolation VFIO expects.

Sources: [S5], [S7]

---

# 8. Determine the actual PVE bootloader

Do not assume that ZFS automatically means systemd-boot. PVE 9 installations can use:

```text
Direct GRUB
Proxmox-Boot-Tool-managed GRUB
Proxmox-Boot-Tool-managed systemd-boot
```

Inspect:

```bash
proxmox-boot-tool status || true
cat /proc/cmdline

if [ -e /etc/default/grub ]; then
    grep -E '^GRUB_CMDLINE_LINUX' /etc/default/grub
fi

if [ -e /etc/kernel/cmdline ]; then
    cat /etc/kernel/cmdline
fi
```

Use exactly one of the following branches.

## 8.1 GRUB branch

Edit:

```bash
nano /etc/default/grub
```

Keep exactly one active assignment:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="..."
```

Preserve every valid existing argument. Append only what is required.

Intel fallback example:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="<existing arguments> intel_iommu=on"
```

Intel fallback with optional passthrough-domain mode:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="<existing arguments> intel_iommu=on iommu=pt"
```

AMD optional passthrough-domain mode:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="<existing arguments> iommu=pt"
```

Regenerate GRUB:

```bash
update-grub
```

## 8.2 systemd-boot branch

Edit:

```bash
nano /etc/kernel/cmdline
```

The file must remain one line. Preserve the existing root, ZFS, boot, console, and other required arguments.

Intel fallback form:

```text
<existing one-line contents> intel_iommu=on
```

Intel with optional passthrough-domain mode:

```text
<existing one-line contents> intel_iommu=on iommu=pt
```

AMD optional passthrough-domain mode:

```text
<existing one-line contents> iommu=pt
```

Refresh the EFI System Partitions:

```bash
proxmox-boot-tool refresh
```

## 8.3 Reboot and verify

```bash
reboot
```

After reboot:

```bash
cat /proc/cmdline

journalctl -b -k | grep -Ei \
    'DMAR|AMD-Vi|IOMMU|interrupt remapping|remapping enabled'

find /sys/kernel/iommu_groups -type l 2>/dev/null | wc -l
```

Do not proceed unless the host has real, populated IOMMU groups.

Sources: [S4], [S5]

---

# 9. Inventory the GPU and every PCI function

List likely graphics and audio devices:

```bash
lspci -Dnnk | grep -A3 -Ei \
    'VGA compatible controller|3D controller|Display controller|Audio device'
```

Show all functions belonging to the selected slot:

```bash
lspci -Dnnk -s "$GPU_SLOT"
```

Show the numeric vendor/device IDs:

```bash
lspci -Dnn -s "$GPU_SLOT"
```

Example:

```text
0000:65:00.0 0300: 1002:73bf
0000:65:00.1 0403: 1002:ab28
0000:65:00.2 0c03: 1002:73a6
0000:65:00.3 0c80: 1002:73a4
```

Enumerate every sysfs function:

```bash
for DEVPATH in /sys/bus/pci/devices/"${GPU_SLOT}".*; do
    [ -e "$DEVPATH" ] || continue

    BDF="${DEVPATH##*/}"

    echo
    echo "===== $BDF ====="
    lspci -Dnnk -s "$BDF"

    printf 'IOMMU group: '
    readlink -f "$DEVPATH/iommu_group" || true
done
```

Record:

```text
<GPU_BDF>
<AUDIO_BDF>
<OPTIONAL_USB_BDF>
<OPTIONAL_UCSI_BDF>

<GPU_ID>
<AUDIO_ID>
<OPTIONAL_USB_ID>
<OPTIONAL_UCSI_ID>
```

Do not copy IDs from another GPU model or another physical card.

---

# 10. Validate the target IOMMU group

Show the target function's group:

```bash
readlink -f "/sys/bus/pci/devices/${GPU_BDF}/iommu_group"
```

Extract the group number:

```bash
GROUP="$(basename "$(readlink -f "/sys/bus/pci/devices/${GPU_BDF}/iommu_group")")"
echo "$GROUP"
```

List every member:

```bash
for DEV in /sys/kernel/iommu_groups/"$GROUP"/devices/*; do
    [ -e "$DEV" ] || continue
    lspci -Dnnk -s "${DEV##*/}"
done
```

## Acceptance rule

Every endpoint device in the group must be:

```text
Passed to the same trusted VM
or
Detached from its host driver
```

An upstream PCIe bridge or root port may appear in the group without being separately passed through, because it often has no active endpoint driver. The important condition is that another host-controlled endpoint cannot remain active in the same inseparable group.

Reject the configuration if the group includes an indispensable:

```text
Host NIC
Boot-storage controller
SAS HBA
USB controller used by the host
Another GPU assigned to another VM
```

If grouping is unsuitable:

```text
1. Update system firmware.
2. Move the GPU to another PCIe slot.
3. Review slot bifurcation and CPU-socket connectivity.
4. Disable unnecessary onboard devices if firmware permits.
5. Test another slot.
6. Consider ACS override only as a last-resort trusted-lab exception.
```

Sources: [S2], [S6], [S18]

---

# 11. Baseline PVE 9 VFIO configuration: make no persistent binding changes yet

Current Proxmox tries to make an assigned PCI device unavailable to the host when the VM starts.

Verify that the in-kernel VFIO driver exists:

```bash
modinfo vfio_pci | head
```

It is acceptable to load it manually for verification:

```bash
modprobe vfio_pci
lsmod | grep -E '^vfio|vfio_'
```

Do not initially create:

```text
/etc/modprobe.d/vfio.conf
/etc/modprobe.d/pve-blacklist.conf
/etc/modprobe.d/iommu_unsafe_interrupts.conf
/etc/modprobe.d/kvm.conf
```

Do not initially add persistent VFIO modules to `/etc/modules`.

Do not add:

```text
vfio_virqfd
```

It is not a separate module on any normal PVE 9 kernel.

## Kernel headers

Do not install headers merely for ordinary GPU passthrough.

VFIO is already provided by the Proxmox kernel.

Headers are required only for an out-of-tree module such as:

```text
vendor-reset
A third-party NIC driver
A third-party storage driver
A vendor DKMS module
```

Sources: [S2], [S6], [S8], [S9]

---

# 12. Ensure that the host is not actively using the target GPU

Inspect the current host driver:

```bash
lspci -Dnnk -s "$GPU_SLOT"
```

Check DRM devices and users:

```bash
ls -l /sys/class/drm 2>/dev/null || true

if command -v fuser >/dev/null 2>&1; then
    fuser -v /dev/dri/* 2>/dev/null || true
fi
```

For NVIDIA, check whether host software is using the card:

```bash
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi
```

Before starting the passthrough VM, stop or reconfigure any host workload using the card.

With the automatic-handoff path, this state before VM startup can be valid:

```text
Kernel driver in use: amdgpu
Kernel driver in use: nouveau
Kernel driver in use: nvidia
```

The critical acceptance condition is:

```text
While the VM is running, the selected PCI functions must be owned by vfio-pci.
```

If Proxmox cannot detach the device, use the escalation ladder beginning in Section 18.

---

# 13. Prepare the VM

## 13.1 Stop the VM cleanly

```bash
qm status "$VMID"
qm shutdown "$VMID" --timeout 120
qm status "$VMID"
```

If the VM is already stopped, continue.

Do not use `kill -9`. Use `qm stop` only as recovery when the guest cannot otherwise be stopped.

## 13.2 Inspect existing VM firmware and machine type

```bash
qm config "$VMID" | grep -E \
    '^(bios|machine|efidisk|boot|vga|balloon|hostpci|args)'
```

For a newly built modern GPU VM, use:

```text
Machine: q35
Firmware: OVMF/UEFI
EFI Disk: present
```

For an existing installed VM:

```text
Do not blindly change SeaBIOS to OVMF.
Do not blindly change i440fx to q35.
Back up or clone the VM first.
Confirm that the guest disk and bootloader can boot in UEFI mode.
```

For a new or already-confirmed UEFI VM:

```bash
qm set "$VMID" -machine q35
qm set "$VMID" -bios ovmf
```

Create the EFI disk through:

```text
VM -> Hardware -> Add -> EFI Disk
```

Select the appropriate storage and guest-specific Secure Boot settings. Windows 11 and macOS/OpenCore do not necessarily use identical EFI-disk options.

## 13.3 Use fixed VM memory

VFIO pins the guest's memory, making dynamic ballooning unsuitable for a dedicated passthrough VM.

```bash
qm set "$VMID" -balloon 0
```

Do not add hugepages yet.

---

# 14. Attach the GPU

## Preferred method: Proxmox GUI

Open:

```text
VM -> Hardware -> Add -> PCI Device
```

Then:

1. Select the correct PCI device.
2. Use **Raw Device** unless a cluster PCI mapping has already been deliberately created.
3. Enable **PCI-Express** for a Q35 VM.
4. Enable **All Functions** when every function in that slot belongs to the GPU and should be assigned.
5. Leave **Primary GPU** disabled during first-stage driver and remote-access setup.
6. Do not add a ROM file or disable ROM-Bar unless a specific problem requires it.

## CLI: pass every function in the slot

Omitting the function number corresponds to Proxmox's **All Functions** behavior:

```bash
qm set "$VMID" -hostpci0 "${GPU_SLOT_QM},pcie=1"
```

Example:

```bash
qm set 200 -hostpci0 65:00,pcie=1
```

## CLI: pass functions separately

Use this when the functions must be represented separately or not every function should be assigned:

```bash
qm set "$VMID" -hostpci0 "${GPU_BDF_QM},pcie=1"
qm set "$VMID" -hostpci1 "${AUDIO_BDF_QM},pcie=1"
```

Add other GPU-owned functions if required:

```bash
qm set "$VMID" -hostpci2 "65:00.2,pcie=1"
qm set "$VMID" -hostpci3 "65:00.3,pcie=1"
```

Verify:

```bash
qm config "$VMID" | grep -E '^(machine|bios|vga|hostpci)'
```

Sources: [S2], [S3]

---

# 15. Keep an emulated display for the first test

During initial guest-driver setup, retain the virtual Proxmox display.

Do not initially use:

```text
x-vga=1
vga: none
```

The virtual display provides a recovery path through NoVNC/SPICE while the physical GPU driver is being installed.

The physical GPU framebuffer is not normally visible through Proxmox NoVNC. Once the physical GPU becomes primary, use:

```text
A monitor attached to the GPU
RDP
VNC running inside the guest
SSH
Another guest-native remote-display system
```

After the guest driver and remote access are confirmed, make the card primary if required:

```bash
qm set "$VMID" -hostpci0 "${GPU_SLOT_QM},pcie=1,x-vga=1"
qm set "$VMID" -vga none
```

Use `x-vga=1` only when the physical GPU should be the guest's primary display. It is not a generic NVIDIA Code 43 fix.

For compute-only use, leave the virtual display enabled and omit `x-vga=1`.

Sources: [S2], [S3]

---

# 16. First VM start and host-side verification

Start the VM:

```bash
qm start "$VMID"
qm status "$VMID"
```

Inspect the generated QEMU command:

```bash
qm showcmd "$VMID" --pretty
```

Inspect host kernel messages:

```bash
journalctl -b -k --since "-5 minutes" | grep -Ei \
    'vfio|DMAR|AMD-Vi|IOMMU|BAR|AER|reset|RMRR|group'
```

While the VM is running:

```bash
lspci -Dnnk -s "$GPU_SLOT"
```

Expected state:

```text
Kernel driver in use: vfio-pci
```

Check every assigned function, not only `.0`.

If automatic handoff works, no driver blacklist or persistent VFIO ID binding is needed.

If the VM fails to start, preserve:

```bash
qm config "$VMID"
qm showcmd "$VMID" --pretty
journalctl -b -k | tail -n 300
```

Do not immediately add every workaround from an old passthrough guide. Match the failure to the escalation sections below.

---

# 17. Guest-specific completion

## 17.1 Windows guest

Install the current AMD, NVIDIA, or Intel guest driver using the vendor-supported Windows package.

Verify in PowerShell:

```powershell
Get-CimInstance Win32_VideoController |
    Format-Table Name, DriverVersion, Status
```

For NVIDIA:

```powershell
nvidia-smi
```

Disable hibernation and Windows Fast Startup for repeatable VFIO shutdown testing:

```powershell
powercfg /hibernate off
```

Perform a complete shutdown:

```powershell
shutdown /s /t 0
```

Do not add these old NVIDIA workarounds by default:

```text
hidden=1
kvm=off
Custom CPU flags intended solely for historical Code 43 behavior
```

Only troubleshoot those if the exact current guest driver reports a reproducible virtualization-related error.

Acceptance:

```text
Device Manager shows no device error.
Vendor driver loads.
Hardware acceleration or compute works.
The VM survives at least three full start/shutdown/start cycles.
```

## 17.2 Linux guest

Inside the guest:

```bash
lspci -nnk | grep -A3 -Ei \
    'VGA compatible controller|3D controller|Display controller|Audio device'
```

Install the appropriate guest distribution driver and firmware.

Possible vendor-specific checks:

```bash
nvidia-smi
```

```bash
rocminfo
```

```bash
vainfo
```

Use only the test applicable to the installed GPU and workload.

## 17.3 macOS/OpenCore guest

This plan assumes that the OpenCore macOS VM already exists and boots without passthrough.

Host-side VFIO mechanics are the same, but macOS GPU compatibility is not generic.

### GPU compatibility requirements

Check the exact GPU family, device ID, and target macOS version against the current Dortania GPU Buyers Guide.

For Monterey and later:

```text
Do not plan on NVIDIA GPU acceleration.
Monterey dropped the remaining Kepler support.
There is no general current NVIDIA/macOS passthrough path.
```

For AMD:

```text
Do not infer compatibility merely from the card being AMD.
Check the exact GPU family and target macOS version.
Navi 3x / RX 7000-series GPUs remain unsupported.
Navi 24 remains unsupported.
Navi 22 is not natively supported and depends on experimental community work.
Other AMD families have version-specific requirements and exceptions.
```

### OpenCore upgrade procedure

Before a macOS or OpenCore upgrade:

1. Back up the VM.
2. Create a usable snapshot where supported by the storage.
3. Remove or disable PCI passthrough.
4. Restore an emulated Proxmox display.
5. Confirm OpenCore still boots.
6. Perform the OS/OpenCore update.
7. Confirm the updated VM boots using the virtual display.
8. Reattach the physical GPU.
9. Repeat the passthrough start/stop validation.

Example temporary removal:

```bash
qm shutdown "$VMID" --timeout 120
qm set "$VMID" -delete hostpci0
qm set "$VMID" -vga vmware
```

If graphics/audio were separate:

```bash
qm set "$VMID" -delete hostpci0
qm set "$VMID" -delete hostpci1
```

### Conditional `ignore_msrs`

Do not set this globally merely because the guest is macOS.

First test it temporarily only when macOS repeatedly resets or boot-loops because of unhandled model-specific register accesses:

```bash
cat /sys/module/kvm/parameters/ignore_msrs
echo 1 > /sys/module/kvm/parameters/ignore_msrs
```

If that change demonstrably fixes the macOS boot failure, persist it:

```bash
cat > /etc/modprobe.d/kvm-macos.conf <<'EOF'
options kvm ignore_msrs=1 report_ignored_msrs=0
EOF

update-initramfs -u -k "$(uname -r)"
reboot
```

This is a host-wide KVM setting even though the reason for adding it is one macOS VM.

Nick Sherlock's macOS guides are useful OpenCore and guest-configuration references, but older articles targeting PVE 6 or PVE 7 must not be used as the source for PVE 9 package names, VFIO modules, or bootloader assumptions.

Sources: [S12], [S13], [S14], [S15], [S16]

---

# 18. Escalation 1: persistent early binding to VFIO

Use this only when Proxmox automatic device handoff fails because the native host driver claims or refuses to release the GPU.

Typical evidence:

```text
Device or resource busy
BAR region already in use
Host driver refuses unbind
VM starts only after manually unbinding the device
```

## 18.1 Record every function ID

```bash
lspci -Dnn -s "$GPU_SLOT"
```

Example only:

```text
GPU_ID=1002:73bf
AUDIO_ID=1002:ab28
USB_ID=1002:73a6
UCSI_ID=1002:73a4
```

## 18.2 Create the VFIO ID list

Create:

```bash
nano /etc/modprobe.d/vfio-pci.conf
```

Example:

```text
options vfio-pci ids=<GPU_ID>,<AUDIO_ID>,<USB_ID>,<UCSI_ID>
```

Use no spaces in the comma-separated ID list.

Do not add an ID for a nonexistent function.

Do not add:

```text
disable_vga=1
```

unless a demonstrated legacy VGA-arbitration problem requires it.

## 18.3 Ensure VFIO loads before the native GPU driver

Choose only the relevant vendor branch.

### AMD

Create:

```bash
cat > /etc/modprobe.d/vfio-softdep.conf <<'EOF'
softdep amdgpu pre: vfio-pci
softdep radeon pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF
```

### NVIDIA

Create:

```bash
cat > /etc/modprobe.d/vfio-softdep.conf <<'EOF'
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep nvidia_drm pre: vfio-pci
softdep nvidia_modeset pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF
```

The `snd_hda_intel` soft dependency lets VFIO claim the selected GPU audio ID before the generic audio driver without globally disabling host audio.

## 18.4 Put the PVE 9 VFIO modules into the initramfs

```bash
for MODULE in vfio vfio_iommu_type1 vfio_pci; do
    grep -qxF "$MODULE" /etc/initramfs-tools/modules ||
        echo "$MODULE" >> /etc/initramfs-tools/modules
done
```

Do not add:

```text
vfio_virqfd
```

Rebuild the current kernel's initramfs:

```bash
update-initramfs -u -k "$(uname -r)"
```

If systemd-boot is in use:

```bash
proxmox-boot-tool refresh
```

Reboot:

```bash
reboot
```

Verify before VM startup:

```bash
lspci -Dnnk -s "$GPU_SLOT"
```

Expected for persistent early binding:

```text
Kernel driver in use: vfio-pci
```

## Identical-device warning

`options vfio-pci ids=` matches vendor/device IDs, not one physical PCI address.

If two identical GPUs have the same IDs:

```text
Both can bind to vfio-pci.
Do not use global ID binding if one identical GPU must remain with the host.
Prefer automatic Proxmox handoff or a carefully designed per-device lifecycle.
```

Sources: [S2], [S7]

---

# 19. Escalation 2: global host-driver blacklisting

Use only if all of the following are true:

```text
Automatic handoff failed.
Early binding plus soft dependencies failed.
The passthrough GPU is dedicated.
The host has another management/display path.
The host does not need the same driver for another GPU.
```

## AMD-only host blacklist

```bash
cat > /etc/modprobe.d/pve-gpu-blacklist.conf <<'EOF'
blacklist amdgpu
blacklist radeon
EOF
```

## NVIDIA-only host blacklist

```bash
cat > /etc/modprobe.d/pve-gpu-blacklist.conf <<'EOF'
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
blacklist nvidiafb
EOF
```

Do not globally blacklist:

```text
snd_hda_intel
```

That driver may serve unrelated host audio functions.

Apply:

```bash
update-initramfs -u -k "$(uname -r)"

if proxmox-boot-tool status 2>/dev/null | grep -qi systemd; then
    proxmox-boot-tool refresh
fi

reboot
```

After reboot:

```bash
lspci -Dnnk -s "$GPU_SLOT"
lsmod | grep -E 'amdgpu|radeon|nouveau|nvidia'
```

If the host needs the blacklisted driver for any other card, do not use this branch.

---

# 20. Escalation 3: boot GPU or system-framebuffer ownership

Use this only when the target card was initialized as the host boot display and errors indicate that the simple/EFI framebuffer still owns its BARs.

First:

```text
Move host primary video to BMC, iGPU, or another GPU.
Disconnect the host console from the passthrough card where practical.
Confirm remote management works.
```

Look for errors:

```bash
journalctl -b -k | grep -Ei \
    'sysfb|simple-framebuffer|simpledrm|efifb|BAR.*reserve|BAR.*busy'
```

A modern conditional kernel argument is:

```text
initcall_blacklist=sysfb_init
```

Add it through the correct GRUB or systemd-boot path from Section 8.

Example Intel combination only when all arguments are independently required:

```text
intel_iommu=on iommu=pt initcall_blacklist=sysfb_init
```

This can remove the local host framebuffer and leave the physical host console blank. Ensure SSH/BMC access first.

Do not begin with broad, copied combinations such as:

```text
video=efifb:off
video=vesafb:off
nomodeset
```

Match any framebuffer workaround to the actual current kernel error.

---

# 21. Escalation 4: ACS override

Use ACS override only if:

```text
The platform otherwise supports IOMMU.
The GPU cannot be moved to a better slot.
Firmware changes do not improve the group.
The environment is a trusted laboratory.
The host is not providing security isolation between untrusted tenants.
```

Possible Proxmox kernel argument:

```text
pcie_acs_override=downstream,multifunction
```

Add it through the correct bootloader branch and reboot.

Then rerun:

```bash
for DEV in /sys/kernel/iommu_groups/*/devices/*; do
    [ -e "$DEV" ] || continue

    GROUP="${DEV#*/iommu_groups/}"
    GROUP="${GROUP%%/*}"

    printf 'IOMMU group %-4s ' "$GROUP"
    lspci -Dnn -s "${DEV##*/}"
done | sort -V
```

Critical limitation:

```text
ACS override can make the kernel display separate groups without creating
real PCIe hardware isolation. A device may still be able to reach memory
outside its apparent synthetic group.
```

Therefore:

```text
Do not treat ACS override as a production or multi-tenant security boundary.
Do not use it merely to make the group listing look cleaner.
```

Sources: [S6], [S7], [S18]

---

# 22. Escalation 5: missing interrupt remapping

Check:

```bash
journalctl -b -k | grep -Ei \
    'DMAR-IR|AMD-Vi.*interrupt|interrupt remapping|remapping enabled'
```

Preferred remediation order:

```text
1. Update BIOS/UEFI.
2. Enable interrupt remapping in firmware.
3. Check for a documented chipset erratum.
4. Use hardware with functional interrupt remapping.
```

Only when VM startup explicitly fails with an error such as:

```text
No interrupt remapping support.
Use allow_unsafe_interrupts to enable VFIO IOMMU support.
```

may the following be tested:

```bash
cat > /etc/modprobe.d/vfio-unsafe-interrupts.conf <<'EOF'
options vfio_iommu_type1 allow_unsafe_interrupts=1
EOF

update-initramfs -u -k "$(uname -r)"
reboot
```

Verify:

```bash
cat /sys/module/vfio_iommu_type1/parameters/allow_unsafe_interrupts
```

Expected when enabled:

```text
Y
```

Risk:

```text
This weakens interrupt isolation.
It can expose the host to instability, data-integrity problems, or a malicious
assigned device.
It is not a routine optimization.
```

Do not add it preemptively.

Sources: [S2], [S7], [S18]

---

# 23. Escalation 6: AMD reset failure and `vendor-reset`

Do not install `vendor-reset` just because the card is AMD.

First prove the reset pattern:

```text
1. Cold-boot the host.
2. Start the VM successfully.
3. Shut the VM down completely.
4. Start it again.
5. Confirm that only the second or later start fails.
6. Confirm reset-related errors in the host kernel log.
```

Inspect:

```bash
journalctl -b -k | grep -Ei \
    'vfio|reset|FLR|device_specific|AMD|AER|BAR'
```

Check available kernel reset methods:

```bash
cat "/sys/bus/pci/devices/${GPU_BDF}/reset_method" 2>/dev/null || true
```

The upstream `vendor-reset` project supports only specific AMD families. Verify that the exact GPU is in the project's current supported-device table before installation.

Because `vendor-reset` is an out-of-tree kernel module:

```text
It requires matching kernel headers.
It must compile against the exact running kernel.
Its compatibility must be rechecked after every major kernel update.
Secure Boot can reject the unsigned DKMS module.
It must be loaded early.
```

## 23.1 Check Secure Boot

```bash
if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state
fi
```

If Secure Boot is enabled, follow the official Proxmox Secure Boot module-signing process. Do not assume an unsigned DKMS module will load.

## 23.2 Install PVE 9 build requirements

```bash
apt update

apt install -y \
    git \
    dkms \
    build-essential \
    proxmox-default-headers \
    "proxmox-headers-$(uname -r)"
```

Verify exact header matching:

```bash
readlink -f "/lib/modules/$(uname -r)/build"
dpkg -l "proxmox-headers-$(uname -r)"
```

If APT cannot find headers for the running kernel:

```text
Do not compile against a different kernel's headers.
Either restore the repository containing the exact package or boot into a
currently supported installed PVE kernel and install its matching headers.
```

## 23.3 Build and install from the upstream repository

```bash
git clone --depth 1 \
    https://github.com/gnif/vendor-reset.git \
    /usr/src/vendor-reset-src

cd /usr/src/vendor-reset-src
dkms install .
```

Do not continue if the DKMS build reports an error.

Verify:

```bash
dkms status
modinfo vendor_reset
```

## 23.4 Load it early

```bash
grep -qxF vendor-reset /etc/initramfs-tools/modules ||
    echo vendor-reset >> /etc/initramfs-tools/modules

cat > /etc/modules-load.d/vendor-reset.conf <<'EOF'
vendor-reset
EOF

update-initramfs -u -k "$(uname -r)"
reboot
```

Verify after reboot:

```bash
lsmod | grep vendor_reset
modinfo vendor_reset
journalctl -b -k | grep -Ei 'vendor.reset|vendor_reset'
```

If the kernel exposes `device_specific` as a supported reset method and the current upstream guidance for the exact card requires it, test temporarily:

```bash
cat "/sys/bus/pci/devices/${GPU_BDF}/reset_method"
echo device_specific > "/sys/bus/pci/devices/${GPU_BDF}/reset_method"
cat "/sys/bus/pci/devices/${GPU_BDF}/reset_method"
```

Do not create a generic persistent reset service unless the exact GPU has been tested and the current upstream project explicitly requires that lifecycle.

Repeat at least three complete VM start/shutdown cycles.

Sources: [S9], [S11], [S12], [S17]

---

# 24. ROM, ROM-Bar, and GPU firmware troubleshooting

Do not add a custom ROM to a configuration that already starts successfully.

A ROM may be necessary when:

```text
The GPU lacks a usable UEFI GOP.
The GPU is the host boot card and its shadow ROM is unavailable to QEMU.
The guest reports a specific firmware initialization failure.
The exact card requires a dumped VBIOS for passthrough.
```

Requirements:

```text
Use a ROM from the exact GPU model, subsystem vendor, memory size, and firmware.
Prefer a ROM dumped from the physical card.
Ensure the ROM contains the required UEFI support for an OVMF guest.
Store the verified file under /usr/share/kvm/.
```

Example only:

```bash
qm set "$VMID" \
    -hostpci0 "${GPU_SLOT_QM},pcie=1,romfile=<exact-verified-vbios.rom>"
```

Do not download an unrelated ROM merely because it uses the same GPU chip.

`rombar=0` is another targeted workaround:

```bash
qm set "$VMID" \
    -hostpci0 "${GPU_SLOT_QM},pcie=1,rombar=0"
```

Use it only when logs or device-specific documentation indicate a ROM-Bar conflict. It is not the normal configuration.

---

# 25. BAR allocation, Above 4G Decoding, and Resizable BAR

For:

```text
Large GPUs
Several GPUs
GPUs with large BARs
PCIe accelerators
```

enable firmware **Above 4G Decoding** first.

Inspect host allocation errors:

```bash
journalctl -b -k | grep -Ei \
    'BAR|MMIO|resource.*failed|no space|cannot reserve'
```

Do not automatically add arbitrary QEMU values such as:

```text
q35-pcihost.pci-hole64-size
```

Those are specialized multi-device/MMIO troubleshooting parameters and must be sized for the actual topology.

Resizable BAR policy:

```text
Start with the firmware default for Windows/Linux.
If initialization or BAR mapping fails, test with ReBAR disabled.
For macOS, begin with ReBAR disabled unless the exact OpenCore setup explicitly
supports the card and BAR configuration.
```

---

# 26. Optional NUMA and performance tuning

Do this only after functional passthrough survives repeated power cycles.

Determine the GPU's host NUMA node:

```bash
cat "/sys/bus/pci/devices/${GPU_BDF}/numa_node"
numactl --hardware 2>/dev/null || true
lspci -tv
```

On dual-socket servers:

```text
Prefer guest vCPUs and memory from the CPU socket physically connected to the GPU.
Avoid crossing UPI/Infinity Fabric unnecessarily.
Validate actual workload performance rather than relying only on topology.
```

Hugepages:

```text
Optional.
Not required for VFIO.
Not an AMD reset fix.
Not a replacement for fixed guest memory.
Must be sized to the actual VM memory allocation.
```

Do not copy this type of old example blindly:

```text
default_hugepagesz=1G hugepagesz=1G hugepages=8
```

A passthrough VM should normally use:

```text
Fixed memory
Ballooning disabled
Enough host RAM left for PVE and other workloads
```

---

# 27. Full validation procedure

## 27.1 Host boot validation

```bash
pveversion -v
uname -r
cat /proc/cmdline

journalctl -b -k | grep -Ei \
    'DMAR|AMD-Vi|IOMMU|interrupt remapping'

find /sys/kernel/iommu_groups -type l | wc -l
```

Acceptance:

```text
The expected kernel booted.
IOMMU groups are populated.
No new fatal IOMMU, DMAR, AMD-Vi, or PCI resource errors appear.
The host remains reachable over its management path.
```

## 27.2 Group validation

```bash
for DEV in /sys/kernel/iommu_groups/*/devices/*; do
    [ -e "$DEV" ] || continue

    GROUP="${DEV#*/iommu_groups/}"
    GROUP="${GROUP%%/*}"

    printf 'IOMMU group %-4s ' "$GROUP"
    lspci -Dnn -s "${DEV##*/}"
done | sort -V
```

Acceptance:

```text
All functions of the target GPU are accounted for.
No indispensable host endpoint shares the group.
No security assumption relies solely on ACS override.
```

## 27.3 VM-off driver validation

Automatic-handoff path:

```text
Native driver or no driver can be acceptable while the VM is off.
```

Persistent early-binding path:

```text
vfio-pci should own every selected function before the VM starts.
```

Check:

```bash
lspci -Dnnk -s "$GPU_SLOT"
```

## 27.4 VM-running driver validation

```bash
qm start "$VMID"
sleep 5
qm status "$VMID"
lspci -Dnnk -s "$GPU_SLOT"
```

Acceptance:

```text
Every assigned function reports Kernel driver in use: vfio-pci.
The host remains reachable.
There are no fatal BAR, reset, RMRR, AER, or IOMMU errors.
```

## 27.5 Guest validation

Windows:

```text
Vendor driver loads.
Device Manager has no error.
nvidia-smi or equivalent vendor validation works.
Hardware acceleration or compute works.
```

Linux:

```text
Expected guest driver owns the device.
Vendor compute/render tool works.
```

macOS:

```text
The exact GPU is supported by that macOS release.
Metal acceleration is active.
The VM boots repeatedly after full shutdown.
```

Inside the macOS guest, capture the display and accelerator registrations:

```bash
system_profiler SPDisplaysDataType |
    egrep 'Chipset Model|Type: GPU|Bus:|PCIe Lane Width|VRAM|Vendor|Device ID|Metal'
ioreg -r -c IOAccelerator -l
```

Require the expected passed-through AMD device and VRAM, a supported Metal
feature set, and an `IOAccelerator` instance. When Xcode command-line tools are
already installed, this optional smoke test also submits a Metal command buffer:

```bash
xcrun swift - <<'SWIFT'
import Metal

if let device = MTLCreateSystemDefaultDevice(),
   let queue = device.makeCommandQueue(),
   let command = queue.makeCommandBuffer() {
    command.commit()
    command.waitUntilCompleted()
    precondition(command.status == .completed)
    print("Metal command completed on: \(device.name)")
} else {
    fatalError("No usable Metal device")
}
SWIFT
```

Registration and an empty command buffer are necessary smoke checks, not a
complete performance qualification. Run a representative Metal render or
compute workload during every reset cycle and preserve its result with the
host-side VFIO and kernel evidence.

## 27.6 Reset-cycle validation

Run at least three cycles:

```text
Cold host boot
VM start
Guest workload test
Full guest shutdown
VM start again
Guest workload test
Full guest shutdown
VM start a third time
```

After each cycle:

```bash
journalctl -b -k | grep -Ei \
    'vfio|reset|AER|BAR|DMAR|AMD-Vi|IOMMU'
```

## 27.7 Production acceptance conditions

The configuration is ready for normal use only when:

```text
IOMMU groups remain stable.
The VM starts reliably.
All intended functions transfer to vfio-pci.
The guest driver initializes successfully.
Three or more complete reset cycles succeed.
The host stays reachable.
No new recurring AER, BAR, or reset errors appear.
No unsafe interrupt or ACS workaround is being mistaken for real isolation.
```

After successful commissioning, autostart may be restored:

```bash
qm set "$VMID" -onboot 1
```

Configure startup order/delay where several passthrough VMs or devices are involved.

Remember:

```text
A VM with a physical PCIe device is tied to compatible hardware.
Ordinary live migration is not available while the physical device is assigned.
```

---

# 28. Rollback procedure

## 28.1 Remove the GPU from the VM

```bash
qm shutdown "$VMID" --timeout 120
qm set "$VMID" -delete hostpci0
```

If separate functions were configured:

```bash
qm set "$VMID" -delete hostpci1
qm set "$VMID" -delete hostpci2
qm set "$VMID" -delete hostpci3
```

Restore a virtual display:

```bash
qm set "$VMID" -vga std
```

Keep autostart disabled until recovery is confirmed:

```bash
qm set "$VMID" -onboot 0
```

## 28.2 Remove only files created by this process

Examples:

```bash
rm -f \
    /etc/modprobe.d/vfio-pci.conf \
    /etc/modprobe.d/vfio-softdep.conf \
    /etc/modprobe.d/pve-gpu-blacklist.conf \
    /etc/modprobe.d/vfio-unsafe-interrupts.conf \
    /etc/modprobe.d/kvm-macos.conf
```

Do not remove an existing administrative file merely because its name appears here. Compare against the backup first.

Manually remove only the lines added by this project from:

```text
/etc/initramfs-tools/modules
```

The PVE 9 VFIO lines are:

```text
vfio
vfio_iommu_type1
vfio_pci
```

## 28.3 Remove `vendor-reset` if installed

Identify the actual version:

```bash
dkms status
```

Then use the exact version shown:

```bash
dkms remove vendor-reset/<VERSION> --all
```

Remove its boot-load files:

```bash
rm -f /etc/modules-load.d/vendor-reset.conf
```

Manually remove `vendor-reset` from:

```text
/etc/initramfs-tools/modules
```

## 28.4 Restore boot arguments

Compare with the backup:

```bash
diff -u "$BACKUP/grub" /etc/default/grub 2>/dev/null || true
diff -u "$BACKUP/cmdline" /etc/kernel/cmdline 2>/dev/null || true
```

Manually remove only the arguments added by this project, such as:

```text
intel_iommu=on
iommu=pt
initcall_blacklist=sysfb_init
pcie_acs_override=downstream,multifunction
amd_iommu=force_enable
```

Do not remove an argument that existed before the passthrough project.

Apply the correct bootloader update:

GRUB:

```bash
update-grub
```

systemd-boot:

```bash
proxmox-boot-tool refresh
```

Rebuild the current initramfs:

```bash
update-initramfs -u -k "$(uname -r)"
```

Reboot:

```bash
reboot
```

If a new kernel caused the regression, select the previous known-good kernel from the boot menu before making further changes. Kernel pinning should be used only after confirming the exact known-good version with:

```bash
proxmox-boot-tool kernel list
```

---

# 29. Proxmox VE 6, 7, 8, and 9 command differences

The primary procedure above is for PVE 9. The following section exists only to identify historical differences.

## 29.1 Kernel-header package names

Headers are needed only for DKMS or another out-of-tree module.

```bash
# Proxmox VE 6
apt update
apt install "pve-headers-$(uname -r)"
```

```bash
# Proxmox VE 7
apt update
apt install "pve-headers-$(uname -r)"
```

```bash
# Proxmox VE 8
apt update
apt install "proxmox-headers-$(uname -r)"
```

```bash
# Proxmox VE 9
apt update
apt install "proxmox-headers-$(uname -r)"
```

Current PVE 9 DKMS preparation:

```bash
apt install \
    dkms \
    build-essential \
    proxmox-default-headers \
    "proxmox-headers-$(uname -r)"
```

Some PVE 8 point releases provide compatibility or transitional package aliases, but new PVE 8/9 scripts should use the native `proxmox-headers-*` name.

## 29.2 VFIO modules are determined by kernel version

### Linux earlier than 6.2

Typical PVE 6 and default PVE 7 module list:

```text
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
```

### Linux 6.2 and later

PVE 7 with the optional 6.2 kernel, all normal PVE 8 kernels, and all PVE 9 kernels:

```text
vfio
vfio_iommu_type1
vfio_pci
```

Do not add:

```text
vfio_virqfd
```

The decision is kernel-based, not solely PVE-major-version-based.

Check:

```bash
uname -r
```

PVE 7 normally used Linux 5.15, but an optional Linux 6.2 kernel was available. Therefore some PVE 7 installations should omit `vfio_virqfd`.

## 29.3 Intel IOMMU arguments

### PVE 6 default kernels

```text
intel_iommu=on
```

Optional:

```text
intel_iommu=on iommu=pt
```

### PVE 7 default 5.x kernels

```text
intel_iommu=on
```

Optional:

```text
intel_iommu=on iommu=pt
```

### PVE 8 with Linux 6.2 or 6.5

Normally use:

```text
intel_iommu=on
```

Optional:

```text
intel_iommu=on iommu=pt
```

### PVE 8 with Linux 6.8 or later

Verify IOMMU groups first. IOMMU is normally enabled by default:

```text
No enable argument required when populated IOMMU groups already exist.
```

Valid fallback:

```text
intel_iommu=on
```

### PVE 9

Verify first. PVE 9 kernels are 6.14 or newer:

```text
No enable argument required when populated IOMMU groups already exist.
```

Valid fallback:

```text
intel_iommu=on
```

Optional:

```text
iommu=pt
```

## 29.4 AMD IOMMU arguments

For PVE 6, 7, 8, and 9:

```text
Enable IOMMU/AMD-Vi in firmware.
Verify populated IOMMU groups.
```

Do not use:

```text
amd_iommu=on
```

That copied setting was not a legitimate PVE requirement. `on` is not a valid Linux AMD-IOMMU parameter value.

Optional on any generation:

```text
iommu=pt
```

Exceptional and caution-required:

```text
amd_iommu=force_enable
```

Never use this as the VFIO fallback:

```text
iommu=soft
```

## 29.5 Proxmox boot-tool naming

Older PVE 6-era documentation may use:

```bash
pve-efiboot-tool refresh
```

The utility was renamed in 2021, with a compatibility symlink retained during the transition.

PVE 7, 8, and 9 use:

```bash
proxmox-boot-tool refresh
```

A robust historical check is:

```bash
if command -v proxmox-boot-tool >/dev/null 2>&1; then
    proxmox-boot-tool refresh
elif command -v pve-efiboot-tool >/dev/null 2>&1; then
    pve-efiboot-tool refresh
else
    echo "No Proxmox boot synchronization tool found"
fi
```

For GRUB-based installations across all versions:

```bash
update-grub
```

The choice between `/etc/default/grub` and `/etc/kernel/cmdline` depends on how that host boots, not simply on the PVE major version.

## 29.6 Concise historical matrix

```text
PVE 6:
  Headers: pve-headers-$(uname -r)
  Typical kernel: below 6.2
  vfio_virqfd: normally present
  Intel IOMMU: intel_iommu=on generally required
  AMD IOMMU: firmware enable; never amd_iommu=on
  Old boot-tool name may be pve-efiboot-tool

PVE 7:
  Headers: pve-headers-$(uname -r)
  Default kernel: 5.15
  vfio_virqfd: present on 5.15
  Optional 6.2 kernel: omit vfio_virqfd
  Intel IOMMU: intel_iommu=on on default kernel
  AMD IOMMU: firmware enable; never amd_iommu=on
  Boot tool: proxmox-boot-tool

PVE 8:
  Headers: proxmox-headers-$(uname -r)
  Kernels: 6.2, 6.5, 6.8 and later depending point release
  vfio_virqfd: omit
  Intel before 6.8: intel_iommu=on
  Intel 6.8+: verify first; normally enabled by default
  AMD: firmware enable; never amd_iommu=on
  Boot tool: proxmox-boot-tool

PVE 9:
  Headers: proxmox-headers-$(uname -r), only when DKMS is needed
  Header meta-package: proxmox-default-headers
  Kernels: 6.14, 6.17, or 7.0 depending installed point/kernel
  vfio_virqfd: omit
  Intel and AMD: verify groups first; normally enabled by firmware/kernel
  Intel fallback: intel_iommu=on
  AMD: never amd_iommu=on
  Boot tool: proxmox-boot-tool
  Preferred binding path: automatic Proxmox handoff first
```

---

# 30. Source register

## Primary Proxmox sources

[S1] Proxmox VE Roadmap
https://pve.proxmox.com/wiki/Roadmap

[S2] Proxmox PCI(e) Passthrough
https://pve.proxmox.com/wiki/PCI%28e%29_Passthrough

[S3] Proxmox `qm(1)` manual
https://pve.proxmox.com/pve-docs/qm.1.html

[S4] Proxmox Host Bootloader
https://pve.proxmox.com/wiki/Host_Bootloader

[S9] Proxmox forum: current kernel-header support discussion
https://forum.proxmox.com/threads/correct-way-to-install-proxmox-kernel-headers-and-related-support-files.174898/

[S10] Proxmox forum: `pve-headers` to `proxmox-headers` transition
https://forum.proxmox.com/threads/install-pve-headers-uname-r-failure.138509/

[S11] Proxmox VE 9.2 release announcement
https://forum.proxmox.com/threads/proxmox-virtual-environment-9-2-available.183741/

[S17] Proxmox Secure Boot setup
https://pve.proxmox.com/wiki/Secure_Boot_Setup

## Primary Linux sources

[S5] Linux kernel command-line parameter documentation
https://docs.kernel.org/admin-guide/kernel-parameters.html

[S6] Linux VFIO documentation
https://docs.kernel.org/driver-api/vfio.html

## Proxmox technical discussions and version corrections

[S7] Proxmox forum: PCI/GPU passthrough configuration and corrections
https://forum.proxmox.com/threads/pci-gpu-passthrough-on-proxmox-ve-8-installation-and-configuration.130218/

[S8] Proxmox VE 8/kernel 6.2 discussion noting `vfio_virqfd` integration
https://forum.proxmox.com/threads/proxmox-ve-8-0-beta-released.128677/

[S18] Proxmox forum discussion of PCI isolation and ACS considerations
https://forum.proxmox.com/threads/nic-card-passthrough-and-essential-things-to-think-about.80805/

[S19] Proxmox development-list boot-tool rename
https://lists.proxmox.com/pipermail/pve-devel/2021-April/047893.html

[S20] Proxmox VE 7 optional Linux 6.2 kernel announcement
https://forum.proxmox.com/threads/opt-in-linux-6-2-kernel-for-proxmox-ve-7-x-available.124189/

## AMD reset and macOS/OpenCore sources

[S12] Upstream `vendor-reset` project
https://github.com/gnif/vendor-reset

[S13] Nick Sherlock: AMD GPU reset workaround on Proxmox
https://www.nicksherlock.com/2020/11/working-around-the-amd-gpu-reset-bug-on-proxmox/

[S14] Nick Sherlock: macOS Ventura/OpenCore on Proxmox
https://www.nicksherlock.com/2022/10/installing-macos-13-ventura-on-proxmox/

[S15] Dortania GPU Buyers Guide
https://dortania.github.io/GPU-Buyers-Guide/

[S16] Dortania AMD GPU compatibility matrix
https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/amd-gpu.html

Dortania NVIDIA GPU compatibility matrix
https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/nvidia-gpu.html
