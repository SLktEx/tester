# Read-only. No arguments are forwarded to wsl.exe from the caller.
$ErrorActionPreference = 'Stop'
$wsl = (Get-Command wsl.exe -CommandType Application | Select-Object -First 1).Source

function Get-WslReport([string]$Arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $wsl
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.StandardOutputEncoding = [Text.Encoding]::Unicode
    # wsl.exe defaults to UTF-16LE on redirected stdout.
    $info.EnvironmentVariables.Remove('WSL_UTF8')
    $process = [Diagnostics.Process]::Start($info)
    try {
        $report = $process.StandardOutput.ReadToEnd().Trim()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "wsl.exe $Arguments (exit $($process.ExitCode)) $report"
        }
        $report
    } finally {
        $process.Dispose()
    }
}

$version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
[pscustomobject]@{
    WindowsBuild = "$($version.CurrentBuild).$($version.UBR)"
    UserWslConfigPresent = Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.wslconfig')
    WslVersionReport = Get-WslReport '--version'
    WslStatus = Get-WslReport '--status'
    Distributions = Get-WslReport '--list --verbose'
} | ConvertTo-Json
