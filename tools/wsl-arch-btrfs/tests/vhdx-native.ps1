# Diagnostic test, NOT a setup script. No attach/terminate/format/snapshot/GUI.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^ArchBtrfs-Vhdx(Lab|Clean)$')][string]$Name,
    [Parameter(Mandatory)][string]$Base,
    [switch]$Apply
)
. "$PSScriptRoot/../scripts/host.ps1"
$Base=[IO.Path]::GetFullPath($Base)
$manifest=Join-Path $Base "$Name.json"
Assert-PlainPath $manifest
$state=Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
Assert-ManagedRegistration $state $Name (Join-Path $Base $Name.Substring(10))
Write-Host "Target: $Name; registration: $($state.Registration)"
Write-Host 'Risk: starts this dedicated distro and creates a local diagnostic log. No stop, attach or guest write.'
Write-Host 'Rollback: none needed for guest data; if Debian is reported, stay in rescue and inspect boot.log.'
if (!$Apply) { Write-Host 'DRY RUN: add -Apply to perform the diagnostic'; return }
$lock=[IO.File]::Open((Join-Path $Base "$Name.lock"),'OpenOrCreate','ReadWrite','None')
$log=Join-Path $Base "$Name-vhdx-probe-$(Get-Date -Format yyyyMMdd-HHmmss)-$PID.log"
try {
    Start-Transcript -LiteralPath $log | Out-Null
    Assert-ManagedRegistration $state $Name (Join-Path $Base $Name.Substring(10))
    $repo=Get-GuestPath (Split-Path $PSScriptRoot)
    $probe=@'
set -eu
instance=$1
d=/.bootstrap/old/var/lib/archbtrfs
[ "$(findmnt -nro FSTYPE /)" = btrfs ] || { echo 'FAIL: Debian rescue, not Arch'; exit 2; }
[ -f "$d/vhdx-mode" ] || { echo 'FAIL: loop mode, not VHDX'; exit 2; }
[ "$(cat /etc/archbtrfs-instance)" = "$instance" ]
uuid=$(cat "$d/uuid")
dev=$("/.bootstrap/old/usr/local/sbin/archvhdx-find-device" "$uuid")
rootdev=$(findmnt -nro SOURCE /)
rootdev=${rootdev%%\[*}
[ "$(readlink -f "$dev")" = "$(readlink -f "$rootdev")" ]
printf 'PASS root-device=%s UUID=%s root=%s init-root=%s\n' "$dev" "$uuid" "$(stat -Lc '%d:%i' /)" "$(stat -Lc '%d:%i' /proc/1/root)"
printf 'mount-namespace=%s PID1-namespace=%s\n' "$(readlink /proc/self/ns/mnt)" "$(readlink /proc/1/ns/mnt)"
'@
    # Two independent Windows -> WSL requests: never accept a nested chroot alone.
    1..2 | ForEach-Object {
        Invoke-LabWsl -d $Name -u root --cd / --exec /bin/sh -c ($probe.Replace("`r`n","`n")) sh $state.Instance
        Invoke-LabWsl -d $Name -u root --cd / --exec /bin/bash "$repo/tests/root.sh" $state.Instance
    }
    $actual=Invoke-LabWsl -d $Name --cd / --exec /bin/sh -c 'id -un; cat /etc/archbtrfs-instance; /mnt/c/Windows/System32/cmd.exe /d /c ver'
    if ($actual[0] -cne 'arch' -or $actual[1] -cne $state.Instance -or ($actual -join ' ') -notmatch 'Microsoft Windows') {
        throw 'New default-user session or Windows interop failed'
    }
    if ((Get-Content -Raw -LiteralPath "\\wsl.localhost\$Name\etc\archbtrfs-instance").Trim() -cne $state.Instance) {
        throw 'Plan9/UNC is pointing at the wrong root'
    }
    Write-Host 'PASS: native root, independent sessions, systemd, interop and UNC'
    Write-Host 'NOT TESTED here: task ACL/UAC, cold attach, GUI/VS Code, concurrency, snapshots, VM idle, clean reproduction'
} finally {
    $lock.Dispose()
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
