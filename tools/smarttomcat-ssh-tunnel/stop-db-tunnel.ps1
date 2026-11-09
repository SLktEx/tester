# Stop only a matching SSH tunnel; never kill an unrelated process on this port.
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$SshHost = 'smarttomcat-db',

    [ValidateRange(1, 65535)]
    [int]$LocalPort = 13306
)

$ErrorActionPreference = 'Stop'
$listeners = @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue)

if ($listeners.Count -eq 0) {
    Write-Output "No SSH tunnel listening on 127.0.0.1:$LocalPort."
    exit 0
}

$aliasPattern = '(?:^|\s)' + [regex]::Escape($SshHost) + '(?:\s|$)'
foreach ($ownerId in @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)) {
    $processInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ownerId" -ErrorAction SilentlyContinue
    if ($null -eq $processInfo -or
        $processInfo.Name -ine 'ssh.exe' -or
        [string]::IsNullOrEmpty($processInfo.CommandLine) -or
        $processInfo.CommandLine -notmatch $aliasPattern) {
        throw "Refusing to stop unrelated or unverified process on port $LocalPort (PID $ownerId)."
    }

    Stop-Process -Id $ownerId -ErrorAction Stop
    Write-Output "Stopped SSH tunnel on 127.0.0.1:$LocalPort (PID $ownerId)."
}
