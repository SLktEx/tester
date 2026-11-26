#!/bin/bash
# Read-only assertions, including content in a nested systemd subvolume.
set -euo pipefail
instance=${1:?}; label=${2:?}; root=${3:-/}
[[ $label =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]
[[ $(cat "$root/etc/archbtrfs-instance") == "$instance" ]]
for p in "home/arch/$label" "var/lib/machines/$label"; do
    [[ $(cat "$root/$p") == baseline ]]
done
echo 'PASS restored root and nested-subvolume payloads'
