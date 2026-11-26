# Exploratory native commands on a fresh GitHub-hosted Windows runner only.
# This is not the production launcher and does not validate normal-token ACLs.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Base,[switch]$Apply)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
   $env:GITHUB_RUN_ID -notmatch '^\d+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^\d+$'){throw 'Ephemeral GitHub-hosted runner required'}
if([IO.Path]::GetFullPath($Base) -cne "C:\ArchBtrfs-Actions\$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"){throw 'Unexpected CI path'}
$name="ArchBtrfs-Actions-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
Write-Host "Target: isolated hosted runner and $name; risk: test VM stop/reconnect; originals retained; no local or self-hosted execution"
if(!$Apply){Write-Host 'DRY RUN';return}
. "$PSScriptRoot/../scripts/host.ps1"
. "$PSScriptRoot/../scripts/Native-Process.ps1"
$labs=Join-Path $Base 'labs'; $evidence=Join-Path $Base 'evidence'
$project=Split-Path $PSScriptRoot; $repo=Get-GuestPath $project
$vhd=Join-Path $Base 'conversion/arch-data.vhdx'
$taskName="WSL-Arch-Actions-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
$state=Get-Content -Raw -LiteralPath (Join-Path $labs "$name.json") | ConvertFrom-Json
$uuid=[IO.File]::ReadAllText((Join-Path $Base 'conversion/uuid')).Trim()
$wsl=Join-Path $env:SystemRoot 'System32/wsl.exe'
function Assert-IsolatedRunner {
    if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Hosted guard changed'}
    Assert-ManagedRegistration $state $name (Join-Path $labs $name.Substring(10))
    $all=@(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\*' -ErrorAction SilentlyContinue | Where-Object DistributionName)
    if($all.Count -ne 1 -or $all[0].DistributionName -cne $name){throw 'Another registered distro exists; VM-wide test refused'}
}
function Wsl([string[]]$Arguments){(Invoke-ArchNative -FilePath $wsl -ArgumentList $Arguments -TimeoutSeconds 90).Output}
function Guest([string[]]$Arguments){Wsl (@('-d',$name,'-u','root','--cd','/','--exec')+$Arguments)}
function Probe-Disk {
    Invoke-ArchNative -FilePath $wsl -ArgumentList @('-d',$name,'-u','root','--cd','/','--exec','bash',"$repo/scripts/Find-ArchVhdxDevice.sh",$uuid) -AllowedExitCodes @(0,1) -TimeoutSeconds 30
}
function Request-Disk {
    $before=(Get-ScheduledTaskInfo -TaskName $taskName).LastRunTime
    Guest @('env',"TASK_NAME=$taskName",'bash',"$repo/scripts/Request-Mount.sh",'--apply') | Out-Host
    $deadline=[datetime]::UtcNow.AddSeconds(90)
    do{
        $task=Get-ScheduledTask -TaskName $taskName
        $info=Get-ScheduledTaskInfo -TaskName $taskName
        if($info.LastRunTime -ne $before -and $task.State -eq 'Ready'){break}
        Start-Sleep -Milliseconds 400
    }while([datetime]::UtcNow -lt $deadline)
    if($info.LastRunTime -eq $before -or $task.State -ne 'Ready' -or $info.LastTaskResult -ne 0 -or (Probe-Disk).ExitCode -ne 0){throw 'Current task completion/disk not verified'}
}
function Reach-Arch([string]$Scenario){
    Assert-IsolatedRunner
    $fs=(Guest @('findmnt','-nro','FSTYPE','/')).Trim()
    if($fs -eq 'ext4'){
        Guest @('bash',"$repo/tests/rescue.sh",$state.Instance) | Out-Host
        Write-Host "$Scenario : first session is Debian rescue"
        if((Probe-Disk).ExitCode -eq 1){Request-Disk}
        Assert-IsolatedRunner
        if((Probe-Disk).ExitCode -ne 0){throw 'Disk lost before target restart'}
        Wsl @('--terminate',$name) | Out-Host
    }elseif($fs -eq 'btrfs'){
        Write-Host "$Scenario : WSL retained/restored attachment before root startup"
    }else{throw 'Unexpected root'}
    # One observed reconnect only. A second missing root fails instead of looping.
    Guest @('bash',"$repo/tests/actions-root.sh",$state.Instance,$repo) | Out-Host
    & "$PSScriptRoot/session.ps1" -Name $name -Base $labs
    Write-Host "PASS $Scenario : verified Arch root, PID1, independent sessions and UNC"
}
Assert-IsolatedRunner
if(!(Test-Path -LiteralPath (Join-Path $evidence 'two-stage-pass.txt'))){throw 'Earlier native phases must pass first'}
$who=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if(!$who.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Hosted administrator token required'}
Start-Transcript -LiteralPath (Join-Path $evidence 'Lifecycle.transcript.log') | Out-Null
$registered=$false
try{
    if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){throw 'Task collision'}
    $action=New-ScheduledTaskAction -Execute $wsl -Argument ('--mount "'+$vhd+'" --vhd --bare')
    $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings | Out-Null
    $registered=$true
    if((Probe-Disk).ExitCode -ne 1){throw 'Earlier test must leave target VHDX detached'}
    Request-Disk
    & "$project/recovery/recover.ps1" -Action Arch -Name $name -Base $labs -Apply
    if(!(Get-Process -Name vmmemWSL -ErrorAction SilentlyContinue)){throw 'Cannot observe WSL VM process; natural idle not verified'}
    # Querying running registrations does not create a Linux client/session.
    $deadline=[datetime]::UtcNow.AddSeconds(180)
    do{
        $running=(Wsl @('--list','--running','--quiet')).Trim()
        $vm=Get-Process -Name vmmemWSL -ErrorAction SilentlyContinue
        if(!$running -and !$vm){break}
        Start-Sleep -Seconds 2
    }while([datetime]::UtcNow -lt $deadline)
    if($running -or $vm){throw 'Natural VM stop not observed in 180 seconds; not a PASS'}
    Write-Host 'PASS natural idle observed: no running distro and prior vmmemWSL process absent'
    Reach-Arch 'after-natural-idle'
    # The global command is ONLY an isolated test case, never a normal launcher.
    Assert-IsolatedRunner
    Wsl @('--shutdown') | Out-Host
    Reach-Arch 'after-explicit-VM-stop'
    & "$project/recovery/recover.ps1" -Action Debian -Name $name -Base $labs -Apply
    Wsl @('--unmount',$vhd) | Out-Host
    Guest @('sha256sum','-c',"$(Get-GuestPath (Join-Path $Base 'conversion'))/source.sha256") | Out-Host
    [IO.File]::WriteAllText((Join-Path $evidence 'lifecycle-pass.txt'),'PASS natural VM idle observation, next launch, explicit isolated VM shutdown and bounded reconnect, Arch/systemd/new sessions/UNC, raw unchanged. Host reboot and normal-token security NOT TESTED.')
}finally{
    if($registered){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
    Stop-Transcript | Out-Null
}
