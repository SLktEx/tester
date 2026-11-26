# Pure orchestration. OS effects are supplied by the Windows adapter.
function Invoke-ArchVhdxBoot {
    param([hashtable]$IO, [hashtable]$Expected,
        [ValidateRange(1,120)][int]$TimeoutSeconds=45,
        [ValidateRange(1,2)][int]$MaxRestarts=2)
    $restarts=0
    while ($true) {
        & $IO.Verify
        $root = & $IO.Root
        if ($root.Fs -eq 'btrfs') {
            if ($root.Uuid -cne $Expected.Uuid -or $root.Instance -cne $Expected.Instance -or
                $root.Subvol -cne '/@' -or !$root.Systemd) { throw 'Arch root identity/PID1 mismatch' }
            & $IO.Log 'ARCH_READY: UUID, instance, subvolume and PID1 verified'
            return 'Arch'
        }
        if ($root.Fs -ne 'ext4' -or !$root.Mode -or $root.Instance -cne $Expected.Instance -or
            $root.Uuid -cne $Expected.Uuid) { throw 'Debian rescue root identity/mode mismatch' }
        & $IO.Log 'DEBIAN_RESCUE: Arch is not ready'
        if ($restarts -ge $MaxRestarts) { throw 'Restart limit reached; Debian rescue retained' }
        $device = & $IO.Device
        if ($device -notin 'ready','absent') { throw 'Invalid device probe result' }
        if ($device -eq 'ready' -and $restarts -gt 0) { throw 'Attached VHDX but pivot failed; inspect boot.log in Debian rescue' }
        if ($device -eq 'absent') {
            $before = & $IO.Task
            if ($before.State -in 'Running','Queued') { throw 'Mount task is already active; retry after it completes' }
            & $IO.Request
            $deadline = (& $IO.Now) + $TimeoutSeconds
            $completed=$false
            while ((& $IO.Now) -lt $deadline) {
                $task = & $IO.Task
                $completed=$false
                if ($task.Generation -ne $before.Generation -and $task.State -eq 'Ready') {
                    if ($task.Result -ne 0) { throw "Mount task failed: $($task.Result); Debian rescue retained" }
                    $completed=$true
                }
                $device = & $IO.Device
                if ($device -notin 'ready','absent') { throw 'Invalid device probe result' }
                if ($completed -and $device -eq 'ready') { break }
                & $IO.Wait
            }
            if (!$completed -or $device -ne 'ready') { throw 'Mount completion/device timeout; no restart, Debian rescue retained' }
        }
        # Revalidate just before the disruptive operation. Attachment retention is
        # not assumed: the next iteration verifies root and permits one reconnect.
        & $IO.Verify
        if ((& $IO.Device) -ne 'ready') { throw 'Device disappeared before restart; Debian rescue retained' }
        & $IO.Log 'TARGET_RESTART: bounded attachment-loss recovery enabled'
        & $IO.Terminate
        $restarts++
    }
}
