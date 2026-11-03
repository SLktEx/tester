#!/bin/bash
set -euo pipefail
repo=$1 inputs=$2 name=$3 instance=$4 marker=$5
[[ $WSL_DISTRO_NAME == "$name" && $(id -u) == 0 && $(findmnt -no FSTYPE /) == ext4 ]]
[[ $instance =~ ^[0-9a-f-]{36}$ && $marker == /mnt/c/* ]]
d=/var/lib/archbtrfs
if [[ ! -d $d ]]; then
    install -d -m 700 "$d"
    printf '%s\n' "$instance" >"$d/instance"
fi
[[ $(realpath "$d") == "$d" && $(stat -c '%u:%a' "$d") == 0:700 && $(cat "$d/instance") == "$instance" ]]
exec 9>"$d/setup.lock"; flock -n 9
exec > >(tee -a "$d/prepare.log") 2>&1
if [[ -f $d/prepared ]]; then
    [[ $(cat "$d/name") == "$name" && $(cat "$d/marker") == "$marker" ]]
    [[ $(blkid -s UUID -o value "$d/arch.img") == "$(cat "$d/uuid")" ]]
    exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Retries=2 update
apt-get -y install btrfs-progs=6.14-1 xz-utils=5.8.1-1+deb13u2
modprobe btrfs
for f in fstab wsl.conf; do
    [[ -f $d/$f.original ]] || cp -a "/etc/$f" "$d/$f.original"
done
printf '%s\n' "$name" >"$d/name"
printf '%s\n' "$marker" >"$d/marker"
img="$d/arch.img"
if [[ ! -f $d/uuid ]]; then
    [[ ! -e $img && ! -L $img ]]
    cat /proc/sys/kernel/random/uuid >"$d/uuid"
fi
if [[ ! -e $img && ! -L $img ]]; then
    (set -C; umask 077; : >"$img")
    [[ -f $img && ! -L $img && $(stat -c '%h:%s' "$img") == 1:0 ]]
    truncate -s 8G "$img"
    mkfs.btrfs -U "$(cat "$d/uuid")" -L ArchWSL "$img"
fi
[[ -f $img && ! -L $img && $(stat -c %h "$img") == 1 ]]
[[ $(blkid -s UUID -o value "$img") == "$(cat "$d/uuid")" ]]
install -d -m 700 "$d/top" "$d/root"
top="$d/top"; ! mountpoint -q "$top" || exit 1
mount -o loop,subvolid=5 "$img" "$top"
trap 'umount "$top"' EXIT
[[ -d $top/@snapshots ]] || btrfs subvolume create "$top/@snapshots"
if [[ ! -e $top/@ ]]; then
    # A failed extraction remains available for inspection. Never overlay it on retry.
    r="$top/@build-$(cat /proc/sys/kernel/random/uuid)"
    btrfs subvolume create "$r"
    tar --numeric-owner --xattrs --acls -xf "$inputs/archlinux.wsl" -C "$r"
    chroot "$r" /usr/bin/useradd -m -u 1000 -s /bin/bash arch
    cp "$d/instance" "$r/etc/archbtrfs-instance"
    install -d -m 0700 "$r/.bootstrap" "$r/.bootstrap/old"
    cp -a /etc/resolv.conf "$r/etc/resolv.conf"
    for p in /usr/bin/wslpath /usr/bin/wslinfo /usr/sbin/mount.drvfs; do
        [[ $(readlink "$p") == /init ]]
        ln -s /init "$r$p"
    done
    printf '[boot]\nsystemd=true\n[user]\ndefault=arch\n' >"$r/etc/wsl.conf"
    mv -T "$r" "$top/@"
fi
cmp "$top/@/etc/archbtrfs-instance" "$d/instance"
if ! getent passwd arch >/dev/null; then useradd -m -u 1000 -s /bin/bash arch; fi
[[ $(id -u arch) == 1000 ]]
cp "$top/@/etc/wsl.conf" /etc/wsl.conf
install -m0755 "$repo/scripts/mount.archbtrfs" /usr/sbin/mount.archbtrfs
mkdir -p /archbtrfs-hook /mnt/c
{ cat "$d/fstab.original"; printf '\nC: /mnt/c drvfs defaults 0 0\nnone /archbtrfs-hook archbtrfs defaults 0 0\n'; } >"$d/fstab.new"
install -m0644 "$d/fstab.new" /etc/fstab
sync
touch "$d/prepared"
