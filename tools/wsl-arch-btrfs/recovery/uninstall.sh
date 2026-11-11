#!/bin/bash
# Restore Debian boot settings and keep the image, snapshots and registration.
set -euo pipefail
echo "Target: instance ${1:?}; risk: restore Debian settings; rollback: saved fstab and wsl.conf"
[[ ${2:-} == --apply ]] || { echo 'DRY RUN: add --apply'; exit 0; }
d=/var/lib/archbtrfs
[[ $(findmnt -no FSTYPE /) == ext4 && $(cat "$d/instance") == "$1" && $(cat "$d/name") == "$WSL_DISTRO_NAME" ]]
cmp /etc/fstab "$d/fstab.new"
cp -a "$d/fstab.original" /etc/fstab
cp -a "$d/wsl.conf.original" /etc/wsl.conf
if [[ -f $d/prepared ]]; then mv -T "$d/prepared" "$d/uninstalled"; fi
sync
