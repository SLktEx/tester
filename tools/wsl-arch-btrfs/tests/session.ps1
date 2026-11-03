param([string]$Name='ArchBtrfs-Clean',[string]$Base=(Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'wsl-arch-btrfs-labs'))
. "$PSScriptRoot/../scripts/host.ps1"
$manifest=Join-Path $Base "$Name.json"
if ($Name -notmatch '^ArchBtrfs-[A-Za-z0-9-]+$') { throw 'Invalid registration name' }
$state=Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
Assert-ManagedRegistration $state $Name (Join-Path $Base $Name.Substring(10))
$repo=Get-GuestPath (Split-Path $PSScriptRoot)
$who=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
Write-Host "Windows administrator token: $($who.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
Invoke-LabWsl -d $Name -u root --cd / --exec /bin/bash "$repo/tests/root.sh" $state.Instance
$actual=(Invoke-LabWsl -d $Name --cd / --exec /bin/sh -lc 'id -un; cat /etc/archbtrfs-instance')
if ($actual[0] -cne 'arch' -or $actual[1] -cne $state.Instance) { throw 'New login root or user mismatch' }
if ((Get-Content -Raw -LiteralPath "\\wsl.localhost\$Name\etc\archbtrfs-instance").Trim() -cne $state.Instance) { throw 'UNC root mismatch' }
