# Start an OpenSSH local port forward before launching SmartTomcat (Windows PowerShell 5.1+).
# The SSH host alias and LocalForward are configured separately in ~/.ssh/config.
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$SshHost = 'smarttomcat-db',

    [ValidateRange(1, 65535)]
    [int]$LocalPort = 13306,

    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'

function Get-LocalListener {
    @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue)
}

function Test-ExpectedSshProcess {
    param([int]$ProcessId)

    $processInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $processInfo -or $processInfo.Name -ine 'ssh.exe' -or [string]::IsNullOrEmpty($processInfo.CommandLine)) {
        return $false
    }

    $aliasPattern = '(?:^|\s)' + [regex]::Escape($SshHost) + '(?:\s|$)'
    return ($processInfo.CommandLine -match $aliasPattern)
}

$existing = @(Get-LocalListener)
if ($existing.Count -gt 0) {
    foreach ($listener in $existing) {
        if (-not (Test-ExpectedSshProcess -ProcessId $listener.OwningProcess)) {
            throw "Local port $LocalPort is already in use by an unrelated process (PID $($listener.OwningProcess))."
        }
    }

    Write-Output "Reusing SSH tunnel on 127.0.0.1:$LocalPort."
    exit 0
}

$sshCommand = Get-Command -Name 'ssh.exe' -CommandType Application -ErrorAction Stop
# BatchMode prevents an invisible interactive prompt from hanging the IDE.
# ExitOnForwardFailure causes ssh to exit when it cannot bind the local port.
$sshArguments = @('-NT', '-o', 'BatchMode=yes', '-o', 'ExitOnForwardFailure=yes', $SshHost)
$started = Start-Process -FilePath $sshCommand.Source -ArgumentList $sshArguments -WindowStyle Hidden -PassThru

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $started.Refresh()
        if ($started.HasExited) {
            throw "ssh.exe exited with code $($started.ExitCode). Verify SSH config, key/agent, host key, and network."
        }

        $listeners = @(Get-LocalListener)
        if ($listeners.Count -gt 0) {
            foreach ($listener in $listeners) {
                if ($listener.OwningProcess -ne $started.Id) {
                    throw "Port $LocalPort was claimed by another process (PID $($listener.OwningProcess))."
                }
            }

            Write-Output "SSH tunnel ready on 127.0.0.1:$LocalPort (PID $($started.Id))."
            exit 0
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Timed out after $TimeoutSeconds seconds waiting for 127.0.0.1:$LocalPort."
}
catch {
    $started.Refresh()
    if (-not $started.HasExited) {
        Stop-Process -Id $started.Id -ErrorAction SilentlyContinue
    }
    throw
}
