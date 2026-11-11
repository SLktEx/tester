# Exploratory integration test. Refuses local/self-hosted machines.
[CmdletBinding()]
param([ValidateSet('Disk','Task')][string]$Phase='Disk',
      [Parameter(Mandatory)][string]$Base, [switch]$Apply)
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:GITHUB_RUN_ID -notmatch '^\d+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^\d+$') {
    throw 'Only an ephemeral GitHub-hosted Actions Windows runner is allowed'
}
$expectedBase="C:\ArchBtrfs-Actions\$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
if ([IO.Path]::GetFullPath($Base) -cne $expectedBase) { throw 'Unexpected CI target directory' }
$name="ArchBtrfs-Actions-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
Write-Host "Target: $name in $Base; phase: $Phase"
Write-Host 'Risk: new test distro/image/task, target-only restarts; recovery: raw/backups retained, runner is disposable'
if (!$Apply) { Write-Host 'DRY RUN'; return }
. "$PSScriptRoot/../scripts/host.ps1"
$who=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (!$who.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Runner does not have an administrator token' }
$project=Split-Path $PSScriptRoot
$labs=Join-Path $Base 'labs'
$evidence=Join-Path $Base 'evidence'
Assert-PlainPath $Base
[IO.Directory]::CreateDirectory($evidence) | Out-Null
$script:LabNativeLog=Join-Path $evidence "$Phase.native.log"
Start-Transcript -LiteralPath (Join-Path $evidence "$Phase.transcript.log") | Out-Null
$repo=Get-GuestPath $project
$output=Join-Path $Base 'conversion'
$vhd=Join-Path $output 'arch-data.vhdx'
$taskName="WSL-Arch-Actions-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
$registered=$false
try {
    Invoke-LabWsl --version
    $existing=@(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\*' -ErrorAction SilentlyContinue |
        Where-Object DistributionName)
    if ($existing.Count) { Invoke-LabWsl --list --verbose }
    else { Write-Host 'Fresh runner: no installed distributions (expected before import)' }
    Write-Host "Administrator=True; Windows=$([Environment]::OSVersion.Version); Image=$env:ImageVersion"
    if ($Phase -eq 'Disk') {
        & "$project/setup.ps1" -Name $name -Base $labs -Apply
        $state=Get-Content -Raw -LiteralPath (Join-Path $labs "$name.json") | ConvertFrom-Json
        Assert-ManagedRegistration $state $name (Join-Path $labs $name.Substring(10))
        & "$PSScriptRoot/session.ps1" -Name $name -Base $labs
        Write-Host 'PASS loop Arch root, systemd, new sessions and UNC'
        & "$project/recovery/recover.ps1" -Action Debian -Name $name -Base $labs -Apply
        Invoke-LabWsl -d $name -u root --cd / --exec /bin/bash "$repo/tests/rescue.sh" $state.Instance
        Invoke-LabWsl -d $name -u root --cd / --exec /usr/bin/apt-get -y --no-install-recommends install qemu-utils
        Invoke-LabWsl -d $name -u root --cd / --exec /bin/bash "$repo/scripts/Convert-ArchImg-ToVhdx.sh" (Get-GuestPath $output) --apply
        # An identical completed conversion must be verified rather than overwritten.
        Invoke-LabWsl -d $name -u root --cd / --exec /bin/bash "$repo/scripts/Convert-ArchImg-ToVhdx.sh" (Get-GuestPath $output) --apply
        Invoke-LabWsl --mount $vhd --vhd --bare
        Invoke-LabWsl -d $name -u root --cd / --exec /bin/bash "$repo/tests/actions-disk.sh" $state.Instance --apply
        # The script above unmounts its own mount before this path-specific detach.
        Invoke-LabWsl --unmount $vhd
        [IO.File]::WriteAllText((Join-Path $evidence 'disk-pass.txt'),'PASS: loop root/systemd/sessions/UNC, conversion+idempotency, native VHDX attach, subvolume snapshot/clone, detach')
    } else {
        $state=Get-Content -Raw -LiteralPath (Join-Path $labs "$name.json") | ConvertFrom-Json
        Assert-ManagedRegistration $state $name (Join-Path $labs $name.Substring(10))
        if (!(Test-Path -LiteralPath (Join-Path $evidence 'disk-pass.txt'))) { throw 'Disk phase has not passed' }
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Task name occupied' }
        $action=New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wsl.exe" -Argument ('--mount "'+$vhd+'" --vhd --bare')
        $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
        $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings | Out-Null
        $registered=$true
        $before=(Get-ScheduledTaskInfo -TaskName $taskName).LastRunTime
        # Exercise the actual Debian -> Windows interop path, not a fake schtasks.
        Invoke-LabWsl -d $name -u root --cd / --exec /usr/bin/env "TASK_NAME=$taskName" /bin/bash "$repo/scripts/Request-Mount.sh" --apply
        $deadline=[datetime]::UtcNow.AddSeconds(90)
        do {
            $task=Get-ScheduledTask -TaskName $taskName
            $info=Get-ScheduledTaskInfo -TaskName $taskName
            if ($info.LastRunTime -ne $before -and $task.State -eq 'Ready') { break }
            Start-Sleep -Milliseconds 500
        } while ([datetime]::UtcNow -lt $deadline)
        $info | Select-Object LastRunTime,LastTaskResult | Format-List | Out-Host
        if ($info.LastRunTime -eq $before -or $task.State -ne 'Ready' -or $info.LastTaskResult -ne 0) { throw 'Mount task did not complete successfully' }
        Invoke-LabWsl -d $name -u root --cd / --exec /bin/bash "$repo/scripts/Find-ArchVhdxDevice.sh" ([IO.File]::ReadAllText((Join-Path $output 'uuid')).Trim())
        [IO.File]::WriteAllText((Join-Path $evidence 'task-pass.txt'),'PASS: actual Debian interop request, Interactive/Highest mount-only task completed, unique expected disk visible. Production ACL and unelevated token NOT TESTED.')
        Invoke-LabWsl --unmount $vhd
    }
} catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $evidence "$Phase.failure.txt")
    throw
} finally {
    if ($registered) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
    # Preserve text evidence only. No distro shutdown/unregister or image deletion.
    if (Test-Path -LiteralPath $labs) {
        Get-ChildItem -LiteralPath $labs -File -Filter '*.log' | Copy-Item -Destination $evidence
    }
    if (Test-Path -LiteralPath $output) {
        Get-ChildItem -LiteralPath $output -File | Where-Object { $_.Name -in 'conversion.log','qemu-info.json','source.sha256','initial-vhdx.sha256' } | Copy-Item -Destination $evidence
    }
    Write-Host 'NOT TESTED: VHDX root pivot, Windows desktop WSLg/VS Code, secure task ACL, unelevated token, full clean setup.'
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
