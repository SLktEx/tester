# Real child processes and file locks; no WSL, task scheduler, or block devices.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../scripts/Native-Process.ps1"
$directory=Join-Path ([IO.Path]::GetTempPath()) ('archbtrfs-process-'+[guid]::NewGuid())
[IO.Directory]::CreateDirectory($directory) | Out-Null
$child=Join-Path $directory 'child.ps1'
$lockChild=Join-Path $directory 'lock-child.ps1'
$lockPath=Join-Path $directory 'operation.lock'
try {
    [IO.File]::WriteAllText($child,'[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); ConvertTo-Json -Compress -InputObject @($args)')
    [IO.File]::WriteAllText($lockChild,'$ErrorActionPreference="Stop"; . $args[0]; try { $held=Enter-ArchOperationLock $args[1]; $held.Dispose(); exit 0 } catch { exit 23 }')
    $pwsh=(Get-Process -Id $PID).Path
    $values=@('space value','quote"value','', '日本語', 'literal $() ` ;')
    $result=Invoke-ArchNative -FilePath $pwsh -ArgumentList (@('-NoProfile','-File',$child)+$values) -TimeoutSeconds 10
    $actual=@(ConvertFrom-Json -InputObject $result.Output)
    if($actual.Count -ne $values.Count){throw 'Argument count changed'}
    for($i=0;$i -lt $values.Count;$i++){if($actual[$i] -cne $values[$i]){throw 'Literal argument changed'}}
    Write-Host 'PASS native literal argument boundaries and Unicode'
    $result=Invoke-ArchNative -FilePath $pwsh -ArgumentList @('-NoProfile','-Command','[Console]::Error.WriteLine("expected"); exit 7') -AllowedExitCodes @(7) -TimeoutSeconds 10
    if($result.ExitCode -ne 7 -or $result.Error.Trim() -ne 'expected'){throw 'Exit/stderr lost'}
    Write-Host 'PASS explicit allowed nonzero and stderr'
    $failed=$false
    try{Invoke-ArchNative -FilePath $pwsh -ArgumentList @('-NoProfile','-Command','exit 8') -TimeoutSeconds 10 | Out-Null}catch{$failed=$true}
    if(!$failed){throw 'Unexpected exit accepted'}
    Write-Host 'PASS unexpected nonzero rejected'
    $watch=[Diagnostics.Stopwatch]::StartNew(); $failed=$false
    try{Invoke-ArchNative -FilePath $pwsh -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -TimeoutSeconds 1 | Out-Null}catch{if($_ -notmatch 'timed out'){throw}; $failed=$true}
    if(!$failed -or $watch.Elapsed.TotalSeconds -gt 8){throw 'Unbounded timeout'}
    Write-Host 'PASS real child timeout bounded'
    $first=Enter-ArchOperationLock $lockPath
    try{
        $failed=$false
        try{$second=Enter-ArchOperationLock $lockPath; $second.Dispose()}catch{$failed=$true}
        if(!$failed){throw 'Concurrent caller acquired lock'}
        $result=Invoke-ArchNative -FilePath $pwsh -ArgumentList @('-NoProfile','-File',$lockChild,"$PSScriptRoot/../scripts/Native-Process.ps1",$lockPath) -AllowedExitCodes @(23) -TimeoutSeconds 10
    }finally{$first.Dispose()}
    $third=Enter-ArchOperationLock $lockPath; $third.Dispose()
    $result=Invoke-ArchNative -FilePath $pwsh -ArgumentList @('-NoProfile','-File',$lockChild,"$PSScriptRoot/../scripts/Native-Process.ps1",$lockPath) -TimeoutSeconds 10
    Write-Host 'PASS concurrent lock rejected in separate process; release permits retry'
}finally{
    foreach($file in $child,$lockChild,$lockPath){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}
    [IO.Directory]::Delete($directory,$false)
}
