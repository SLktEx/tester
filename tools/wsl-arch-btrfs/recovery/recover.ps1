param(
    [Parameter(Mandatory)][ValidateSet('Debian','Arch','Snapshot','Restore','Uninstall')][string]$Action,
    [ValidatePattern('^ArchBtrfs-[A-Za-z0-9-]+$')][string]$Name='ArchBtrfs-Clean',
    [string]$Base=(Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'wsl-arch-btrfs-labs'),
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')][string]$Label='baseline'
)
. "$PSScriptRoot/../scripts/host.ps1"
$state=Get-Content -Raw -LiteralPath (Join-Path $Base "$Name.json") | ConvertFrom-Json
Assert-ManagedRegistration $state $Name (Join-Path $Base $Name.Substring(10))
$lock=[IO.File]::Open((Join-Path $Base "$Name.lock"),'Open','ReadWrite','None')
try {
    $repo=Get-GuestPath (Split-Path $PSScriptRoot)
    $marker=Join-Path $Base "enable-$Name"
    Assert-PlainPath $marker
    if ($Action -in 'Debian','Restore','Uninstall') {
        if (Test-Path -LiteralPath $marker) { Rename-Item -LiteralPath $marker -NewName "off-$Name-$([guid]::NewGuid())" }
        Invoke-LabWsl --terminate $Name
        $fs=(Invoke-LabWsl -d $Name -u root --cd / --exec /usr/bin/findmnt -nro FSTYPE /).Trim()
        if ($fs -ne 'ext4') { throw 'Rescue boot failed' }
    }
    if ($Action -in 'Snapshot','Restore') {
        Invoke-LabWsl -d $Name -u root --cd / --exec /bin/bash "$repo/recovery/snapshot.sh" $Action.ToLowerInvariant() $Label $state.Instance
    }
    if ($Action -in 'Arch','Restore') {
        if (!(Test-Path -LiteralPath $marker)) { [IO.File]::Open($marker,'CreateNew','Write','None').Dispose() }
        Invoke-LabWsl --terminate $Name
        Invoke-LabWsl -d $Name -u root --cd / --exec /bin/bash "$repo/tests/root.sh" $state.Instance
    }
    if ($Action -eq 'Uninstall') {
        Invoke-LabWsl -d $Name -u root --cd / --exec /bin/bash "$repo/recovery/uninstall.sh" $state.Instance
        Invoke-LabWsl --terminate $Name
    }
} finally { $lock.Dispose() }
