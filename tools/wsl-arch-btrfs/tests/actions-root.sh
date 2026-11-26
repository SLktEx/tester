#!/bin/bash
# Read-only assertions for the native pivot experiment.
set -euo pipefail
instance=${1:?}; repo=${2:?}
[[ $EUID == 0 && $WSL_DISTRO_NAME == ArchBtrfs-Actions-* ]]
bash "$repo/tests/root.sh" "$instance"
d=/.bootstrap/old/var/lib/archbtrfs
[[ -f $d/vhdx-mode ]]
device=$(bash "$repo/scripts/Find-ArchVhdxDevice.sh" "$(cat "$d/uuid")")
findmnt -nro SOURCE,FSTYPE,UUID,FSROOT,MAJ:MIN /
lsblk -dnro NAME,TYPE,MAJ:MIN "$device"
# Btrfs has an anonymous superblock dev_t; its mount MAJ:MIN is not the
# underlying disk's dev_t. Check the canonical SOURCE as well as UUID/@.
source=$(findmnt -nro SOURCE /)
source=${source%%\[*}
[[ $(readlink -f "$source") == "$(readlink -f "$device")" ]]
[[ $(stat -Lc '%d:%i' /etc/wsl.conf) == "$(stat -Lc '%d:%i' /.bootstrap/old/etc/wsl.conf)" ]]
[[ -z $(losetup -j "$d/arch.img") ]]
(cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /d /c ver)
printf 'PASS VHDX root: device=%s UUID=%s FSROOT=%s PID1=%s\n' "$device" "$(findmnt -nro UUID /)" "$(findmnt -nro FSROOT /)" "$(readlink /proc/1/exe)"
