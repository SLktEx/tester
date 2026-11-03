# Exercises only a managed test registration. Leaves the restored Arch running.
param([ValidatePattern('^ArchBtrfs-Clean[A-Za-z0-9-]*$')][string]$Name='ArchBtrfs-Clean',
      [string]$Base=(Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'wsl-arch-btrfs-labs'))
. "$PSScriptRoot/../scripts/host.ps1"
$project=Split-Path $PSScriptRoot
$repo=Get-GuestPath $project
$state=Get-Content -Raw -LiteralPath (Join-Path $Base "$Name.json") | ConvertFrom-Json
Assert-ManagedRegistration $state $Name (Join-Path $Base $Name.Substring(10))
$label="check-$([guid]::NewGuid().ToString('N'))"
$probe="/home/arch/$label"
Start-Transcript -LiteralPath (Join-Path $Base "$Name-$label.log") | Out-Null
try {
    Invoke-LabWsl --terminate $Name
    & "$PSScriptRoot/session.ps1" -Name $Name -Base $Base
    Write-Host 'PASS cold boot, new process, PID1, native UNC'
    Invoke-LabWsl -d $Name --cd / --exec /usr/bin/touch $probe
    $before=(Invoke-LabWsl -d $Name --cd / --exec /usr/bin/findmnt -nro 'UUID,OPTIONS' /).Trim()
    & "$project/setup.ps1" -Name $Name -Base $Base
    $after=(Invoke-LabWsl -d $Name --cd / --exec /usr/bin/findmnt -nro 'UUID,OPTIONS' /).Trim()
    if ($before -ne $after) { throw 'Repeat setup changed root mount' }
    Invoke-LabWsl -d $Name --cd / --exec /usr/bin/test -f $probe
    Write-Host 'PASS repeat setup preserves root and home'
    & "$project/recovery/recover.ps1" -Action Snapshot -Label $label -Name $Name -Base $Base
    Invoke-LabWsl -d $Name --cd / --exec /usr/bin/mv -T $probe "$probe.after"
    & "$project/recovery/recover.ps1" -Action Restore -Label $label -Name $Name -Base $Base
    Invoke-LabWsl -d $Name --cd / --exec /usr/bin/test -f $probe
    Invoke-LabWsl -d $Name --cd / --exec /usr/bin/test '!' -e "$probe.after"
    Write-Host 'PASS snapshot and boot from restored root'
    & "$project/recovery/recover.ps1" -Action Debian -Name $Name -Base $Base
    $injected=$false
    try { & "$project/setup.ps1" -Name $Name -Base $Base -TestFailureAfterPrepare }
    catch {
        if ($_.Exception.Message -ne 'Injected interruption after prepare, before activation') { throw }
        $injected=$true
    }
    if (!$injected -or (Test-Path -LiteralPath (Join-Path $Base "enable-$Name"))) { throw 'Failure injection did not leave rescue active' }
    & "$project/setup.ps1" -Name $Name -Base $Base
    Invoke-LabWsl -d $Name --cd / --exec /usr/bin/test -f $probe
    Write-Host 'PASS injected prepare failure and retry'
    Invoke-LabWsl -d $Name --cd '~' --exec /bin/bash "$repo/tests/integration.sh" $state.Instance
    Write-Host 'PASS interop, WSLg, VS Code remote extension host'
} finally { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }
