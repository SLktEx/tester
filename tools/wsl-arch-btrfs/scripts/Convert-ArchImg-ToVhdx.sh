#!/bin/bash
# Derived from the successful manual Lab conversion. Does not attach or enable VHDX.
set -euo pipefail
[[ $# == 1 || ( $# == 2 && $2 == --apply ) ]] || { echo 'Usage: Convert-ArchImg-ToVhdx.sh NEW_OUTPUT_DIRECTORY [--apply]' >&2; exit 2; }
out=$1
[[ $out == /mnt/c/* && $out != *$'\n'* && $out != *$'\r'* && $out != *'"'* && $out != */../* && $out != */./* && $out != */ ]] || exit 2
parent=$(dirname -- "$out")
[[ -d $parent && $(realpath -e -- "$parent") == "$parent" && ! -L $out ]] || exit 2
echo "Target: $out/arch-data.vhdx (new output only); risk: conversion takes disk space; rollback: raw and incomplete outputs retained"
[[ ${2:-} == --apply ]] || { echo 'DRY RUN: no guest mount or output creation'; exit 0; }
[[ $EUID == 0 && ${WSL_DISTRO_NAME:-} == ArchBtrfs-* && $(findmnt -nro FSTYPE /) == ext4 ]]
d=/var/lib/archbtrfs
[[ $(realpath -e "$d") == "$d" && $(stat -c '%u:%a' "$d") == 0:700 ]]
[[ $(cat "$d/name") == "$WSL_DISTRO_NAME" && ! -e $(cat "$d/marker") && ! -e $d/vhdx-mode ]]
src=$d/arch.img
instance=$(cat "$d/instance")
uuid=$(cat "$d/uuid")
[[ -f $src && ! -L $src && $(stat -c '%h:%s' "$src") == 1:8589934592 ]]
[[ $(blkid -p -s TYPE -o value "$src") == btrfs && $(blkid -p -s UUID -o value "$src") == "$uuid" ]]
command -v qemu-img >/dev/null
exec 9>"$d/setup.lock"; flock -n 9
[[ -z $(losetup -j "$src") ]]
finder=$(dirname -- "${BASH_SOURCE[0]}")/Find-ArchVhdxDevice.sh
rc=0
bash "$finder" "$uuid" >/dev/null || rc=$?
[[ $rc == 1 ]] || { echo 'Same UUID attached or device inventory unsafe; refuse conversion' >&2; exit 2; }
if [[ -e $out ]]; then
    # Do not resume or overwrite a partial conversion. A completed, pristine
    # result is idempotent; an attached or modified VHDX requires explicit review.
    [[ -d $out && -f $out/complete && ! -L $out/arch-data.vhdx ]]
    [[ $(cat "$out/instance") == "$instance" && $(cat "$out/uuid") == "$uuid" ]]
    (cd "$out"; sha256sum -c initial-vhdx.sha256)
    sha256sum -c "$out/source.sha256"
    qemu-img compare -f raw -F vhdx "$src" "$out/arch-data.vhdx"
    echo 'PASS existing verified conversion (image unchanged)'; exit 0
fi
mkdir -m 0700 -- "$out" # atomic reservation; collision never overwrites
exec > >(tee -a "$out/conversion.log") 2>&1
printf '%s\n' "$instance" >"$out/instance"
printf '%s\n' "$uuid" >"$out/uuid"
sha256sum "$src" >"$out/source.sha256"
verify=$(mktemp -d "$d/convert-verify.XXXXXX")
mounted=false
cleanup() {
    if $mounted; then umount "$verify" || return; fi
    rmdir "$verify"
}
trap cleanup EXIT
# Standalone nologreplay was removed in kernel 6.16. ro alone can replay logs.
mount -o loop,ro,rescue=nologreplay,subvolid=5 "$src" "$verify"
mounted=true
cmp "$d/instance" "$verify/@/etc/archbtrfs-instance"
test -x "$verify/@/usr/lib/systemd/systemd"
btrfs subvolume show "$verify/@"
btrfs subvolume show "$verify/@snapshots"
umount "$verify"; mounted=false
for _ in {1..50}; do [[ -z $(losetup -j "$src") ]] && break; sleep .1; done
[[ -z $(losetup -j "$src") ]]
sha256sum -c "$out/source.sha256"
qemu-img --version
qemu-img convert -f raw -O vhdx -o subformat=dynamic "$src" "$out/arch-data.vhdx"
qemu-img compare -f raw -F vhdx "$src" "$out/arch-data.vhdx"
sha256sum -c "$out/source.sha256"
qemu-img info --output=json "$out/arch-data.vhdx" >"$out/qemu-info.json"
(cd "$out"; sha256sum arch-data.vhdx >initial-vhdx.sha256)
sync -f "$out/arch-data.vhdx"
printf 'complete\n' >"$out/complete"
echo 'PASS conversion; source retained; VHDX not attached or enabled'
