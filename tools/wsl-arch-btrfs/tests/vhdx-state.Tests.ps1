# No WSL, disks, tasks or elevation: exercise the boot state machine with fakes.
$ErrorActionPreference = 'Stop'
$core = Join-Path $PSScriptRoot '../scripts/Vhdx-State.ps1'
if (!(Test-Path -LiteralPath $core)) { throw 'RED: VHDX state machine is not implemented yet' }
. $core
$script:passed = 0
function Assert($value, [string]$why) { if (!$value) { throw $why } }
function Scenario([string]$name, [scriptblock]$test) {
    $script:s = @{ Tick=0; Stops=0; Requests=0; Boot=0; Events=@(); Present=$false;
        Result=0; Complete=$true; Visible=$true; Lost=0; BadRoot=$false; Duplicate=$false;
        RequestFails=$false; Stale=$false; FailVerify=$false; PivotFails=$false }
    $script:expected = @{ Uuid='f7e561c4-7408-4107-874a-72bd117b24fc'; Instance='12345678-1234-1234-1234-123456789abc' }
    $script:io = @{
        Verify = { if ($s.FailVerify) { throw 'identity mismatch' }; $s.Events += 'verify' }
        Root = {
            $fs = if ($s.Boot -gt 0 -and $s.Present -and !$s.PivotFails) { 'btrfs' } else { 'ext4' }
            @{ Fs=$fs; Uuid=$(if ($s.BadRoot) { 'wrong' } else { $expected.Uuid });
                Instance=$expected.Instance; Subvol='/@'; Systemd=$true; Mode=$true }
        }
        Device = {
            if ($s.Duplicate) { throw 'duplicate UUID' }
            if ($s.Present) { 'ready' } else { 'absent' }
        }
        Task = {
            @{ Generation=$(if ($s.Requests -gt 0 -and !$s.Stale) { $s.Requests } else { 0 });
                State=$(if ($s.Complete -or $s.Requests -eq 0) { 'Ready' } else { 'Running' }); Result=$s.Result }
        }
        Request = {
            $s.Requests++; $s.Events += 'request'
            if ($s.RequestFails) { throw 'elevation failed' }
            if ($s.Visible) { $s.Present=$true }
        }
        Terminate = {
            $s.Stops++; $s.Boot++; $s.Events += 'terminate'
            if ($s.Lost -gt 0) { $s.Lost--; $s.Present=$false }
        }
        Now = { $s.Tick }
        Wait = { $s.Tick++ }
        Log = { param($message) $s.Events += $message }
    }
    & $test
    $script:passed++
    Write-Output "PASS $name"
}
function Boot { Invoke-ArchVhdxBoot -IO $io -Expected $expected -TimeoutSeconds 3 -MaxRestarts 2 }
function Reject([scriptblock]$action, [string]$pattern) {
    $caught=$null
    try { & $action | Out-Null } catch { $caught=$_.Exception.Message }
    Assert ($caught -and $caught -match $pattern) "Expected '$pattern', got '$caught'"
}
Scenario 'cold: request, completed task, device, target restart, verified Arch' {
    Assert ((Boot) -eq 'Arch') 'not Arch'; Assert ($s.Requests -eq 1 -and $s.Stops -eq 1) 'wrong transitions'
}
Scenario 'already Arch is idempotent' {
    $s.Boot=1; $s.Present=$true
    Assert ((Boot) -eq 'Arch') 'not Arch'; Assert ($s.Requests -eq 0 -and $s.Stops -eq 0) 'unneeded mutation'
}
Scenario 'attached disk does not request a second mount' {
    $s.Present=$true; Boot | Out-Null
    Assert ($s.Requests -eq 0 -and $s.Stops -eq 1) 'duplicate request'
}
Scenario 'task exit failure even when disk becomes visible' {
    $s.Result=5; Reject { Boot } 'task.*5'; Assert ($s.Stops -eq 0) 'terminated on failed task'
}
Scenario 'task request is not completion' {
    $s.Complete=$false; Reject { Boot } 'timeout'; Assert ($s.Stops -eq 0) 'terminated running task'
}
Scenario 'old success result is not current completion' {
    $s.Stale=$true; Reject { Boot } 'timeout'; Assert ($s.Stops -eq 0) 'accepted stale task'
}
Scenario 'successful task without visible expected disk times out' {
    $s.Visible=$false; Reject { Boot } 'timeout'; Assert ($s.Stops -eq 0) 'terminated missing disk'
}
Scenario 'request/elevation failure preserves rescue' {
    $s.RequestFails=$true; Reject { Boot } 'elevation'; Assert ($s.Stops -eq 0) 'terminated after failure'
}
Scenario 'duplicate UUID never initiates a mount task' {
    $s.Duplicate=$true; Reject { Boot } 'duplicate'; Assert ($s.Requests -eq 0 -and $s.Stops -eq 0) 'mutated ambiguous disk'
}
Scenario 'registration mismatch makes no guest calls' {
    $s.FailVerify=$true; Reject { Boot } 'identity'; Assert ($s.Requests -eq 0 -and $s.Stops -eq 0) 'mutated wrong distro'
}
Scenario 'wrong already-running Btrfs instance is rejected' {
    $s.Boot=1; $s.Present=$true; $s.BadRoot=$true; Reject { Boot } 'root identity'
}
Scenario 'wrong subvolume is rejected' {
    $io.Root = { @{ Fs='btrfs'; Uuid=$expected.Uuid; Instance=$expected.Instance; Subvol='/@other'; Systemd=$true } }
    Reject { Boot } 'root identity'; Assert ($s.Stops -eq 0) 'terminated wrong root'
}
Scenario 'systemd/PID1 mismatch is rejected' {
    $io.Root = { @{ Fs='btrfs'; Uuid=$expected.Uuid; Instance=$expected.Instance; Subvol='/@'; Systemd=$false } }
    Reject { Boot } 'root identity'
}
Scenario 'Debian without enabled VHDX mode is not restarted' {
    $io.Root = { @{ Fs='ext4'; Uuid=$expected.Uuid; Instance=$expected.Instance; Mode=$false } }
    Reject { Boot } 'rescue root'; Assert ($s.Stops -eq 0 -and $s.Requests -eq 0) 'modified loop mode'
}
Scenario 'one attachment loss allows bounded reconnect' {
    $s.Lost=1; Assert ((Boot) -eq 'Arch') 'not reconnected'
    Assert ($s.Requests -eq 2 -and $s.Stops -eq 2) 'retry count'
}
Scenario 'repeated VM loss stops in rescue, no endless loop' {
    $s.Lost=10; Reject { Boot } 'restart limit'; Assert ($s.Stops -eq 2) 'unbounded restart'
}
Scenario 'attached disk but failed pivot stops without restart loop' {
    $s.PivotFails=$true; Reject { Boot } 'pivot'; Assert ($s.Stops -eq 1) 'repeated failed pivot'
}
Write-Output "TOTAL: $script:passed PASS (mock only; not Windows/WSL integration)"
