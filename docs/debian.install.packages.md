- `apt install xfce4 xfce4-goodies xrdp dbus-x11 ufw`
apt update && apt upgrade -y
apt-get install \
ca-certificates \
curl \
gnupg \
lsb-release \
apt-transport-https \
ca-certificates \ 
curl \ 
gnupg2 \
software-properties-common
- `tree openssh-server net-tools lshw xattr git htop nmon mdadm xfce4 xrdp ufw`
* ZFS install
- apt install zfsutils-linux
- lsmod | grep zfs
- `apt install lsw`
apt update && apt install -y nvme-cli hdparm util-linux curl dmidecode htop fio mdadm xattr tree lshw git python3 sudo iperf smartmontools lsscsi mailutils ksh lvm2 dstat atop nmon iotop xrdp xfce4 xfce4-goodies xorg dbus-x11 x11-xserver-utils ufw task-lxde-desktop firmware-realtek
### Gdebi
> `apt install gdebi-core`
### KDiskMark
- `add-apt-repository ppa:jonmagon/kdiskmark`
- `apt update`
- `apt install kdiskmark`
- `apt install ./filename.deb
- `dpkg –i filename.deb`
- `gdebi filename.deb`
## Installing ROCm
- `sudo apt update`
- `sudo apt install git python3-pip python3-venv python3-dev libstdc++-12-dev`
## DEBUG:
- `sudo amdgpu-install --usecase=hiplibsdk,rocm,graphics,workstation --opencl=rocm --headless`
## Installing ROCm
- `sudo apt update`
- `sudo apt install git python3-pip python3-venv python3-dev libstdc++-12-dev`
sudo apt-get update
sudo apt-get install cifs-utils

## packages to add:
- `lshw`
- `xattr`
- `git`
- `iperf`: bandwidth testing on the local network
## AMD Drivers
* list drivers install: `ls -R /lib/modules/`uname -r`/kernel/`
* list displays pci ports: `lspci |grep -E "VGA|3D"`
* `apt install git binutils initramfs-tools`
* `apt install firmware-amd-graphics` : https://packages.debian.org/bullseye/firmware-amd-graphics
* (https://is.gd/XBEDKv)[install debian amd packaged repo]
* (https://is.gd/tFfBP8)[install amd package tool]
* show attached amd cards: `lspci -k | grep -EA2 'VGA|3D'`
* add drivers:
  - `apt install inxi`
  - `inxi -G --display`
  - `apt install firmware-linux firmware-linux-nonfree libdrm-amdgpu1 xserver-xorg-video-amdgpu`
* confirg driver usage: `dpkg -l | grep amdgpu`
* download drivers:
  - `wget https://repo.radeon.com/amdgpu-install/22.20/ubuntu/jammy/amdgpu-install_22.20.50200-1_all.deb -O ~/amd/amdgpu-install_22.20.50200-1_all.deb`
* extract drivers:
  - `dpkg-deb -xv {file.to.extract.deb} {/path/to/where/extract}`
* view driver files: `dpkg -c {file.deb}`
* install drivers: `apt install ./amdgpu-install_22.20.50200-1_all.deb`
* amd install: `amdgpu-install  --usecase=workstation --opencl=rocr --vulkan=amdvlk,pro --accept-eula`
* install linux gpu drivers:
  - `git clone git://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git`
  - `cd linux-firmware/`
  - `cp -va amdgpu/ /lib/firmware/` or `rsync -avh amdgpu/* /lib/firmware/amdgpu`
  - `sudo update-initramfs -u` : even as `root`
  - `systemctl reboot`
## NVIDIA DRIVERS

