#!/usr/bin/env bash
# Run from an *already initialized interactive WSL shell* (NOT /etc/fstab).
# Requests only the pre-registered mount task; it does not restart or format.
set -euo pipefail
[[ $# == 0 || ( $# == 1 && $1 == --apply ) ]] || { echo 'Usage: Request-Mount.sh [--apply]' >&2; exit 2; }
TASK_NAME=${TASK_NAME:-WSL-Arch-VHD-Mount}
SCHTASKS=${SCHTASKS:-/mnt/c/Windows/System32/schtasks.exe}
case "$TASK_NAME" in WSL-Arch-*) ;; *) echo 'Invalid task name' >&2; exit 2;; esac
[[ "$TASK_NAME" =~ ^WSL-Arch-[A-Za-z0-9_-]+$ ]] || { echo 'Invalid task name' >&2; exit 2; }
if [[ ! -e "$SCHTASKS" ]]; then
    echo "Windows executable is not accessible at $SCHTASKS. Check DrvFs /mnt/c." >&2
    exit 2
fi
if [[ -z ${WSL_INTEROP:-} ]]; then
    echo 'WSL_INTEROP is missing. Run this from a normal interactive WSL shell after init, not fstab.' >&2
    exit 2
fi
printf 'Target: %s; risk: VHDX attach; rollback: Debian rescue, then explicit detach.\n' "$TASK_NAME"
if [[ ${1:-} != --apply ]]; then echo 'DRY RUN: add --apply'; exit 0; fi
printf 'Requesting Windows Scheduled Task: %s\n' "$TASK_NAME"
"$SCHTASKS" /Run /TN "$TASK_NAME"
printf '\nTask start requested (NOT completion confirmed).\n'
printf 'Windows: Get-ScheduledTaskInfo -TaskName "%s" | Select LastRunTime,LastTaskResult\n' "$TASK_NAME"
printf 'Linux:   lsblk -o NAME,SIZE,FSTYPE,UUID,TYPE,MOUNTPOINTS\n'
