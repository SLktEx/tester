#!/bin/bash
# Read-only regression: a fallback Debian boot must not enter emergency mode.
set -euo pipefail
instance=${1:?expected instance}
[[ $EUID == 0 && $WSL_DISTRO_NAME == ArchBtrfs-* ]]
[[ $(findmnt -nro FSTYPE /) == ext4 ]]
[[ $(cat /var/lib/archbtrfs/instance) == "$instance" ]]
[[ $(cat /var/lib/archbtrfs/name) == "$WSL_DISTRO_NAME" ]]
[[ $(readlink /proc/1/exe) == /usr/lib/systemd/systemd ]]
[[ $(timeout 45 systemctl is-system-running --wait) == running ]]
[[ -z $(systemctl --failed --no-legend --plain) ]]
[[ -z $(losetup -j /var/lib/archbtrfs/arch.img) ]]
echo 'PASS Debian/ext4 rescue: systemd running; no failed units; raw image detached'
