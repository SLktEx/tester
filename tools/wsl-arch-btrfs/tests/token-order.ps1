# Start from a normal PowerShell. One UAC prompt covers the two elevated samples.
[CmdletBinding()]
param(
    [ValidatePattern('^ArchBtrfs-Clean[A-Za-z0-9-]*$')][string]$Name='ArchBtrfs-Clean02',
    [switch]$ElevatedLeg,
    [guid]$Trial = [guid]::NewGuid()
)
. "$PSScriptRoot/../scripts/host.ps1"
$Base=Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'wsl-arch-btrfs-labs'
$state=Get-Content -Raw -LiteralPath (Join-Path $Base "$Name.json") | ConvertFrom-Json
Assert-ManagedRegistration $state $Name (Join-Path $Base $Name.Substring(10))
$principal=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$admin=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($admin -ne $ElevatedLeg.IsPresent) { throw "Unexpected Windows token. Administrator=$admin" }
$run="/run/archbtrfs-token-$Trial"
$evidence="/var/tmp/archbtrfs-token-$Trial"

function Measure-View([string]$Phase) {
    # A direct new process must see the same Btrfs root as PID 1 even if its mount ns differs.
    $probe=@'
set -eu
p=$1; f=$2; phase=$3; expected=$4
[ "$(cat /etc/archbtrfs-instance)" = "$expected" ]
[ "$(cat /proc/1/comm)" = systemd ]
[ "$(stat -Lc '%d:%i' /proc/1/root)" = "$(stat -Lc '%d:%i' /)" ]
[ "$(findmnt -nro FSTYPE,FSROOT /)" = 'btrfs /@' ]
case "$phase" in
    normal-first) (umask 077; set -C; echo normal >"$p"; : >"$f") ;;
    elevated-second) [ "$(cat "$p")" = normal ] ;;
    elevated-first) [ ! -e "$p" ]; (umask 077; set -C; echo elevated >"$p") ;;
    normal-second) [ "$(cat "$p")" = elevated ] ;;
    *) exit 2 ;;
esac
printf '%s %s %s %s %s %s\n' "$phase" "$(readlink /proc/self/ns/mnt)" "$(readlink /proc/1/ns/pid)" "$(findmnt -nro UUID /)" "$(findmnt -nro FSROOT /)" "$(stat -Lc '%d:%i' /)" >>"$f"
'@
    Invoke-LabWsl -d $Name -u root --cd / --exec /bin/sh -c ($probe.Replace("`r`n","`n")) sh $run $evidence $Phase $state.Instance
    & "$PSScriptRoot/session.ps1" -Name $Name -Base $Base
}

function Start-Keeper {
    # Bound the lifetime even on cancellation. UAC has already been accepted here.
    Start-Process -FilePath "$env:windir\System32\wsl.exe" -WindowStyle Hidden -ArgumentList @('-d',$Name,'--cd','/','--exec','/usr/bin/sleep','180') | Out-Null
}
function Stop-TrialDistro {
    Invoke-LabWsl --terminate $Name
    # The service can still list a terminating instance after --terminate returns.
    $deadline=[datetime]::UtcNow.AddSeconds(60)
    do {
        if (@(Invoke-LabWsl --list --running --quiet) -notcontains $Name) { return }
        Start-Sleep -Milliseconds 500
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'Distro still listed as running after 60 seconds. Check for reconnecting clients.'
}
if ($ElevatedLeg) {
    $ready=[Threading.EventWaitHandle]::OpenExisting("Local\ArchBtrfs-$Trial-ready")
    $measured=[Threading.EventWaitHandle]::OpenExisting("Local\ArchBtrfs-$Trial-measured")
    $null=$ready.Set()
    if (!$measured.WaitOne([timespan]::FromMinutes(3))) { throw 'Timed out waiting for normal-first measurement' }
    Measure-View elevated-second
    Stop-TrialDistro
    Measure-View elevated-first
    Start-Keeper
    exit 0
}
$log=Join-Path $Base "$Name-token-$Trial.log"
$ready=[Threading.EventWaitHandle]::new($false,'ManualReset',"Local\ArchBtrfs-$Trial-ready")
$measured=[Threading.EventWaitHandle]::new($false,'ManualReset',"Local\ArchBtrfs-$Trial-measured")
Start-Transcript -LiteralPath $log | Out-Null
try {
    # Request the Windows token before starting or measuring either WSL instance.
    $argsForUac=@('-NoProfile','-NonInteractive','-File',('"{0}"' -f $PSCommandPath),'-Name',$Name,'-ElevatedLeg','-Trial',$Trial.ToString())
    $elevated=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -Verb RunAs -WindowStyle Hidden -WorkingDirectory "$env:windir\System32" -ArgumentList $argsForUac -PassThru
    if (!$ready.WaitOne([timespan]::FromSeconds(30))) { throw 'Elevated observer did not signal readiness' }
    Write-Host 'Elevated observer confirmed Windows administrator token: True'
    Stop-TrialDistro
    Measure-View normal-first
    Start-Keeper
    $null=$measured.Set()
    $elevated.WaitForExit()
    if ($elevated.ExitCode -ne 0) { throw "Elevated trial failed (exit $($elevated.ExitCode)). Partial evidence: $evidence" }
    Measure-View normal-second
    $rows=@(Invoke-LabWsl -d $Name -u root --cd / --exec /usr/bin/cat $evidence)
    $rows | ForEach-Object {Write-Host $_}
    if ($rows.Count -ne 4) { throw 'Incomplete trial' }
    for ($i=0; $i -lt 4; $i+=2) {
        $first=$rows[$i] -split ' '
        $second=$rows[$i+1] -split ' '
        if ($first.Count -ne 6 -or $second.Count -ne 6 -or
            ($first[2..5] -join ' ') -ne ($second[2..5] -join ' ') -or $first[1] -eq $second[1]) {
            throw 'Expected two mount namespaces in the same instance with matching Btrfs roots'
        }
    }
    Write-Host 'PASS both Windows token orders'
} finally {
    $ready.Dispose()
    $measured.Dispose()
    Stop-Transcript | Out-Null
}
