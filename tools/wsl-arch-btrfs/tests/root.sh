#!/bin/bash
set -euo pipefail
source /etc/os-release
[[ $ID == arch && $(cat /etc/archbtrfs-instance) == "$1" ]]
[[ $(readlink /proc/1/exe) == /usr/lib/systemd/systemd ]]
[[ $(stat -Lc '%d:%i' /proc/1/root) == "$(stat -Lc '%d:%i' /)" ]]
d=/.bootstrap/old/var/lib/archbtrfs
uuid=$(cat "$d/uuid")
for path in / /etc /usr /var /home; do
    [[ $(findmnt -nro FSTYPE,UUID,FSROOT -T "$path") == "btrfs $uuid /@" ]]
done
[[ $(timeout 45 systemctl is-system-running --wait) == running ]]
getconf GNU_LIBC_VERSION
btrfs subvolume show / | head -12
