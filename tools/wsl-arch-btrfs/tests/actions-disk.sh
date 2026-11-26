#!/bin/bash
# Real block-device test, restricted to the ephemeral CI registration.
set -euo pipefail
instance=${1:?}
[[ ${2:-} == --apply ]] || { echo 'DRY RUN: mounted VHDX snapshot test'; exit 0; }
[[ $EUID == 0 && $WSL_DISTRO_NAME == ArchBtrfs-Actions-* && $(findmnt -nro FSTYPE /) == ext4 ]]
d=/var/lib/archbtrfs
[[ $(cat "$d/instance") == "$instance" && $(cat "$d/name") == "$WSL_DISTRO_NAME" ]]
[[ ! -e $(cat "$d/marker") && -z $(losetup -j "$d/arch.img") ]]
device=$(bash "$(dirname -- "${BASH_SOURCE[0]}")/../scripts/Find-ArchVhdxDevice.sh" "$(cat "$d/uuid")")
if findmnt -rn -S "$device"; then echo 'Device already mounted' >&2; exit 2; fi
echo "Target: $device; risk: test snapshot/subvolume writes; rollback: preserved @ and raw image"
top=$(mktemp -d /run/archvhdx-actions.XXXXXX)
mounted=false
trap 'if $mounted; then umount "$top"; fi; rmdir "$top"' EXIT
mount -t btrfs -o subvolid=5 "$device" "$top"
mounted=true
[[ $(findmnt -nro UUID -T "$top") == "$(cat "$d/uuid")" ]]
cmp "$d/instance" "$top/@/etc/archbtrfs-instance"
btrfs subvolume show "$top/@"
[[ ! -e $top/@snapshots/actions-baseline && ! -e $top/@actions-restored ]]
btrfs subvolume snapshot -r "$top/@" "$top/@snapshots/actions-baseline"
printf 'mutation\n' >"$top/@/var/tmp/actions-probe"
btrfs subvolume snapshot "$top/@snapshots/actions-baseline" "$top/@actions-restored"
[[ ! -e $top/@actions-restored/var/tmp/actions-probe ]]
cmp "$top/@actions-restored/etc/archbtrfs-instance" "$d/instance"
[[ $(btrfs property get "$top/@snapshots/actions-baseline" ro) == ro=true ]]
sync
umount "$top"; mounted=false
echo 'PASS real VHDX device, UUID/instance, read-only snapshot, writable restored clone (not boot restoration)'
