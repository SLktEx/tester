[CmdletBinding()]
param([string]$Bash, [string]$Python='python')
$ErrorActionPreference='Stop'
if (!$Bash) {
    $gitBash=Join-Path ${env:ProgramFiles} 'Git/bin/bash.exe'
    if (Test-Path -LiteralPath $gitBash) { $Bash=$gitBash } else { throw 'Pass -Bash explicitly; never use the WSL bash.exe alias for unit tests' }
}
$version=& $Bash --version
if ($LASTEXITCODE -ne 0) { throw 'Bash runtime unavailable; no tests passed' }
Write-Host $version[0]
$old=$env:TEST_BASH
try {
    $env:TEST_BASH=$Bash
    & $Python "$PSScriptRoot/test_vhdx_shell.py"
    if ($LASTEXITCODE -ne 0) { throw 'Bash behavior tests failed' }
    & "$PSScriptRoot/vhdx-state.Tests.ps1"
    $scripts=Get-ChildItem (Split-Path $PSScriptRoot) -Recurse -Filter '*.ps1'
    foreach ($script in $scripts) {
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tokens,[ref]$errors) | Out-Null
        if ($errors.Count) { throw "$($script.Name): $errors" }
    }
    Write-Host "PASS PowerShell syntax ($($scripts.Count) scripts); no native WSL validation claimed"
} finally { $env:TEST_BASH=$old }
