#!/bin/bash
set -euo pipefail
action=$1 label=$2 instance=$3
echo "Target: instance $instance; action $action label $label; rollback: retained subvolumes"
[[ ${4:-} == --apply ]] || { echo 'DRY RUN: add --apply'; exit 0; }
[[ $label =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]]
case "$action" in
    snapshot)
        d=/.bootstrap/old/var/lib/archbtrfs
        [[ $(findmnt -no FSTYPE /) == btrfs && $(cat /etc/archbtrfs-instance) == "$instance" ]] ;;
    restore)
        d=/var/lib/archbtrfs
        [[ $(findmnt -no FSTYPE /) == ext4 ]] ;;
    *) exit 2 ;;
esac
[[ $(cat "$d/instance") == "$instance" && $(cat "$d/name") == "$WSL_DISTRO_NAME" ]]
[[ ! -e $d/vhdx-mode ]] || { echo 'VHDX mode requires verified VHDX recovery; refusing raw clone mount' >&2; exit 2; }
img="$d/arch.img"
[[ -f $img && ! -L $img && $(blkid -s UUID -o value "$img") == "$(cat "$d/uuid")" ]]
exec 9>"$d/setup.lock"; flock -n 9
top=$(mktemp -d /run/archbtrfs-top.XXXXXX)
mount -o loop,subvolid=5 "$img" "$top"
trap 'cd /; umount "$top" && rmdir "$top"' EXIT
cd "$top"
snap="@snapshots/$label"
if [[ $action == snapshot ]]; then
    [[ ! -e $snap ]]
    sync
    btrfs subvolume snapshot -r @ "$snap"
else
    [[ $(btrfs property get "$snap" ro) == ro=true && $(cat "$snap/etc/archbtrfs-instance") == "$instance" ]]
    pending="@restore-$label"
    if [[ ! -e $pending ]]; then
        btrfs subvolume snapshot "$snap" "$pending"
    else
        # Resume only a clone of this immutable snapshot, in this instance.
        expected=$(btrfs subvolume show "$snap" | awk '$1=="UUID:" {print $2}')
        parent=$(btrfs subvolume show "$pending" | awk '$1=="Parent" && $2=="UUID:" {print $3}')
        [[ -n $expected && $parent == "$expected" && $(cat "$pending/etc/archbtrfs-instance") == "$instance" ]]
    fi
    if [[ -e @ ]]; then mv -T @ "@before-restore-$(cat /proc/sys/kernel/random/uuid)"; fi
    mv -T "$pending" @
    sync
fi
