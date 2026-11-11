#!/bin/bash
# Read-only assertions for the forthcoming native pivot experiment.
set -euo pipefail
instance=${1:?}; repo=${2:?}
[[ $EUID == 0 && $WSL_DISTRO_NAME == ArchBtrfs-Actions-* ]]
bash "$repo/tests/root.sh" "$instance"
d=/.bootstrap/old/var/lib/archbtrfs
[[ -f $d/vhdx-mode ]]
device=$(bash "$repo/scripts/Find-ArchVhdxDevice.sh" "$(cat "$d/uuid")")
[[ $(findmnt -nro MAJ:MIN /) == "$(lsblk -dnro MAJ:MIN "$device")" ]]
[[ $(stat -Lc '%d:%i' /etc/wsl.conf) == "$(stat -Lc '%d:%i' /.bootstrap/old/etc/wsl.conf)" ]]
[[ -z $(losetup -j "$d/arch.img") ]]
(cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /d /c ver)
printf 'PASS VHDX root: device=%s UUID=%s FSROOT=%s PID1=%s\n' "$device" "$(findmnt -nro UUID /)" "$(findmnt -nro FSROOT /)" "$(readlink /proc/1/exe)"
