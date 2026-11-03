#!/bin/sh
# Run inside an already-open test session. Diagnostic output, not a pass/fail test.
set -eu
printf 'kernel=%s distro=%s uid=%s\n' "$(uname -r)" "${WSL_DISTRO_NAME:-unknown}" "$(id -u)"
cat /etc/os-release
for p in / /etc /usr /var /home /init /run /mnt/wslg; do
    [ -e "$p" ] || continue
    printf '%s ' "$p"
    findmnt --noheadings --target "$p" --output TARGET,SOURCE,FSTYPE,FSROOT,MAJ:MIN,PROPAGATION
done
for p in self 1; do
    printf '/proc/%s root (device:inode) ' "$p"
    stat -Lc '%d:%i' "/proc/$p/root" || printf 'unavailable\n'
    for ns in mnt pid; do
        printf '%s ' "$ns"
        readlink "/proc/$p/ns/$ns" || printf 'unavailable\n'
    done
done
cat /proc/1/comm
printf '\nActive filesystems and loop support\n'
grep -w btrfs /proc/filesystems || :
ls -ld /dev/loop-control /sys/module/loop /sys/module/btrfs 2>/dev/null || :
printf '\nMount tree for this session\n'
cat /proc/self/mountinfo
