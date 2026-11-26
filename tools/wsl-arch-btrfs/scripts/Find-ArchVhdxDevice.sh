#!/usr/bin/env bash
# Read-only. 0=one whole Btrfs disk, 1=absent, >=2=unsafe/error.
set -euo pipefail
[[ $# == 1 && $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || exit 2
expected=${1,,}
inventory=$(lsblk -nrpo NAME,TYPE) || { echo 'lsblk failed' >&2; exit 3; }
found=()
while read -r dev typ extra; do
    [[ -n $dev ]] || continue
    [[ $dev == /dev/* && -z ${extra:-} ]] && test -b "$dev" || {
        echo 'Invalid block inventory' >&2; exit 3; }
    uuid=$(blkid -p -s UUID -o value "$dev" 2>/dev/null) || {
        rc=$?; [[ $rc == 2 ]] && continue
        echo "Cannot safely probe $dev (rc=$rc)" >&2; exit 3; }
    [[ "${uuid,,}" == "$expected" ]] || continue
    fstype=$(blkid -p -s TYPE -o value "$dev") || exit 3
    # Same-UUID loop/partition is not an absent VHDX. Never mount both clones.
    [[ $typ == disk && $fstype == btrfs ]] || { echo "Unsafe UUID match: $dev $typ $fstype" >&2; exit 4; }
    found+=("$dev")
done <<<"$inventory"
(( ${#found[@]} != 0 )) || exit 1
(( ${#found[@]} == 1 )) || { echo 'Duplicate Btrfs UUID' >&2; exit 5; }
printf '%s\n' "${found[0]}"
