#requires -Version 7.0
# Bounded UTF-8 client execution (WSL_UTF8=1). Other clients must emit UTF-8.
# Timeout kills only the client created here, never a
# distro or the WSL VM. A timed-out OS operation may still require inspection.
function Invoke-ArchNative {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath,
          [string[]]$ArgumentList=@(),
          [ValidateRange(1,300)][int]$TimeoutSeconds=45,
          [int[]]$AllowedExitCodes=@(0))
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$FilePath
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $start.Environment['WSL_UTF8']='1'
    foreach($argument in $ArgumentList){$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$start
    try {
        if(!$process.Start()){throw 'Native client failed to start'}
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit($TimeoutSeconds*1000)){
            if(!$process.HasExited){$process.Kill($false)}
            $null=$process.WaitForExit(3000)
            throw 'Native client timed out; OS operation may be pending. No distro/VM was terminated.'
        }
        # Descendants can retain redirected handles after the client exits.
        if(![Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),3000)){
            throw 'Native output handles did not close; inspect pending operation'
        }
        $result=[pscustomobject]@{ExitCode=$process.ExitCode;Output=$stdout.Result;Error=$stderr.Result}
        if($result.ExitCode -notin $AllowedExitCodes){throw "Native client failed with exit $($result.ExitCode): $($result.Error.Trim())"}
        return $result
    } finally { $process.Dispose() }
}

function Enter-ArchOperationLock {
    param([Parameter(Mandatory)][string]$Path)
    # Callers validate registration/path identity before acquiring this lock.
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            if((Get-Item -Force -LiteralPath $cursor).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Operation lock path contains a reparse point'}
        }
        $parent=[IO.Directory]::GetParent($cursor)
        $cursor=if($parent){$parent.FullName}else{$null}
    }
    try { return [IO.File]::Open($Path,'OpenOrCreate','ReadWrite','None') }
    catch { throw 'Another operation holds the lock, or its file is inaccessible; no guest operation started' }
}
