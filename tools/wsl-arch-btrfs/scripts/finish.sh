#!/bin/bash
set -euo pipefail
repo=$1 inputs=$2 instance=$3
[[ $(cat /etc/archbtrfs-instance) == "$instance" && $(findmnt -no FSTYPE /) == btrfs ]]
d=/.bootstrap/old/var/lib/archbtrfs
[[ $(cat "$d/instance") == "$instance" ]]
exec > >(tee -a "$d/finish.log") 2>&1
if [[ ! -f /var/lib/archbtrfs-finished ]]; then
    cd "$inputs/packages"
    sha256sum --quiet -c "$repo/scripts/arch-packages.sha256"
    packages=()
    while read -r digest file; do
        [[ $file == *.pkg.tar.zst ]] && packages+=("$PWD/$file")
    done < "$repo/scripts/arch-packages.sha256"
    pacman-key --init
    pacman-key --populate archlinux
    conf=$(mktemp /run/archbtrfs-pacman.XXXXXX)
    trap 'unlink "$conf"' EXIT
    sed 's/^LocalFileSigLevel.*/LocalFileSigLevel = Required/' /etc/pacman.conf >"$conf"
    grep -qx 'LocalFileSigLevel = Required' "$conf"
    pacman --config "$conf" -U --needed --noconfirm "${packages[@]}"
    for exe in btrfs wget xmessage xwininfo wayland-info pactl; do command -v "$exe"; done
    touch /var/lib/archbtrfs-finished
fi
