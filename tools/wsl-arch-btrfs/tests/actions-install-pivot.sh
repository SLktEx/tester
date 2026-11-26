#!/bin/bash
# Install experimental fixture only in a fresh hosted Actions guest.
set -euo pipefail
instance=${1:?}; repo=${2:?}
echo "Target: ${WSL_DISTRO_NAME:-unknown} early hook; risk: failed boot; recovery: disable Windows enable marker, restore saved helper"
[[ ${3:-} == --apply ]] || { echo 'DRY RUN'; exit 0; }
[[ $EUID == 0 && $WSL_DISTRO_NAME == ArchBtrfs-Actions-* ]]
[[ $(findmnt -nro FSTYPE /) == ext4 ]]
d=/var/lib/archbtrfs
[[ $(cat "$d/name") == "$WSL_DISTRO_NAME" && $(cat "$d/instance") == "$instance" ]]
[[ ! -e $(cat "$d/marker") && -z $(losetup -j "$d/arch.img") ]]
[[ ! -e $d/actions-original-helper && ! -e $d/vhdx-mode ]]
cp -a /sbin/mount.archbtrfs "$d/actions-original-helper"
install -m 700 "$repo/scripts/Find-ArchVhdxDevice.sh" "$d/Find-ArchVhdxDevice.sh"
install -m 755 "$repo/tests/fixtures/mount.archbtrfs-vhdx" /sbin/mount.archbtrfs
touch "$d/vhdx-mode"
touch "$(cat "$d/marker")"
echo 'PASS experimental helper installed; original helper and raw retained'
