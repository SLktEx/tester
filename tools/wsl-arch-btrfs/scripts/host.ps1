$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

function Invoke-LabWsl {
    & wsl.exe @args
    if ($LASTEXITCODE -ne 0) { throw "wsl.exe failed (exit $LASTEXITCODE): $args" }
}

function Get-Registration([string]$Name) {
    @(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\*' -ErrorAction SilentlyContinue |
        Where-Object DistributionName -eq $Name) | Select-Object -First 1
}

function Assert-PlainPath([string]$Path) {
    $itemPath = [IO.Path]::GetFullPath($Path)
    while ($itemPath) {
        if (Test-Path -LiteralPath $itemPath) {
            $item = Get-Item -Force -LiteralPath $itemPath
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $itemPath" }
        }
        $parent = [IO.Directory]::GetParent($itemPath)
        if ($null -eq $parent) { break }
        $itemPath = $parent.FullName
    }
}

function Assert-ManagedRegistration($State, [string]$Name, [string]$Path) {
    $reg = Get-Registration $Name
    if (!$reg -or $reg.Version -ne 2 -or $State.Name -cne $Name -or $State.Path -ine $Path -or
        ($reg.BasePath -replace '^\\\\\?\\','') -ine $Path -or $reg.PSChildName -ine $State.Registration) {
        throw "Registration identity mismatch: $Name"
    }
    Assert-PlainPath $Path
}

function Get-GuestPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^C:\\' -or $full -match '[\r\n]') { throw "A local C: path is required: $full" }
    '/mnt/c/' + $full.Substring(3).Replace('\','/')
}

function Get-VerifiedInput([string]$Path, [string]$Hash, [string]$Url) {
    Assert-PlainPath $Path
    if (!(Test-Path -LiteralPath $Path)) {
        $part = "$Path.$([guid]::NewGuid()).download"
        & curl.exe --fail --silent --show-error --location --retry 2 --output $part $Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url" }
        if ((Get-FileHash -LiteralPath $part).Hash -ine $Hash) { throw "Download checksum mismatch: $part" }
        [IO.File]::Move($part,$Path)
    } elseif ((Get-FileHash -LiteralPath $Path).Hash -ine $Hash) {
        throw "Existing input checksum mismatch: $Path"
    }
}
