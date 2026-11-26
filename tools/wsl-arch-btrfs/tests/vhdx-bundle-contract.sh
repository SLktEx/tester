#!/bin/bash
# Native acceptance test. Run only in an approved, offline dedicated rescue distro.
set -euo pipefail
instance=${1:?}; label=${2:?}
echo "Target: dedicated instance $instance; snapshot/restore $label; retains previous root; requires Debian rescue"
[[ ${3:-} == --apply ]] || { echo 'DRY RUN'; exit 0; }
script=$(realpath "$(dirname "$0")/../recovery/vhdx-bundle.sh")
[[ -f $script ]]
[[ $label =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]
[[ ${WSL_DISTRO_NAME:-} =~ ^ArchBtrfs-[A-Za-z0-9-]+$ && $EUID == 0 ]]
[[ $(findmnt -nro FSTYPE /) == ext4 && -z $(findmnt -rn -t btrfs) ]]
d=/var/lib/archbtrfs
[[ $(cat "$d/instance") == "$instance" && $(cat "$d/name") == "$WSL_DISTRO_NAME" && -f $d/vhdx-mode ]]
[[ ! -e $(cat "$d/marker") && -z $(losetup -j "$d/arch.img") ]]
device=$(bash "$d/Find-ArchVhdxDevice.sh" "$(cat "$d/uuid")")
top=$(mktemp -d /run/archbtrfs-contract.XXXXXX)
trap 'if mountpoint -q "$top"; then umount "$top"; fi; rmdir "$top"' EXIT
mount -t btrfs -o subvolid=5 "$device" "$top"
[[ $(cat "$top/@/etc/archbtrfs-instance") == "$instance" ]]
[[ ! -e $top/@/home/arch/$label && ! -e $top/@/var/lib/machines/$label ]]
btrfs subvolume create "$top/@/var/lib/machines/$label"
btrfs subvolume create "$top/@/var/lib/machines/$label/nested space"
printf 'baseline\n' > "$top/@/home/arch/$label"
printf 'baseline\n' > "$top/@/var/lib/machines/$label/nested space/payload"
sync; umount "$top"
bash "$script" snapshot "$label" "$instance" --apply
bash "$script" snapshot "$label" "$instance" --apply
mount -t btrfs -o subvolid=5 "$device" "$top"
printf 'changed\n' > "$top/@/home/arch/$label"
printf 'changed\n' > "$top/@/var/lib/machines/$label/nested space/payload"
sync; umount "$top"
[[ ! -e $d/restore-$label.ids && ! -L $d/restore-$label.ids && ! -e $d/missing-$label ]]
ln -s "$d/missing-$label" "$d/restore-$label.ids"
rc=0
bash "$script" restore "$label" "$instance" --apply || rc=$?
[[ $rc != 0 && -L $d/restore-$label.ids && ! -e $d/missing-$label ]]
[[ $(readlink "$d/restore-$label.ids") == "$d/missing-$label" ]]
unlink "$d/restore-$label.ids"
echo 'PASS dangling journal symlink refused without following or replacing it'
rc=0
ARCHBTRFS_TEST_STOP=after-old-rename bash "$script" restore "$label" "$instance" --apply || rc=$?
[[ $rc == 75 ]]
[[ $(findmnt -nro FSTYPE /) == ext4 ]]
bash "$script" restore "$label" "$instance" --apply
bash "$script" restore "$label" "$instance" --apply
mount -t btrfs -o ro,rescue=nologreplay,subvolid=5 "$device" "$top"
for relative in "home/arch/$label" "var/lib/machines/$label/nested space/payload"; do
    [[ $(cat "$top/@/$relative") == baseline ]]
    [[ $(cat "$top/@before-restore-$label/$relative") == changed ]]
done
umount "$top"
[[ -z $(findmnt -rn -t btrfs) ]]
echo 'PASS native bundle: deep nested content restored, old content retained, snapshot twice, interrupted restore, resumed restore twice, mounts released'
