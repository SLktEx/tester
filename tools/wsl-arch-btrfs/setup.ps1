[CmdletBinding()]
param(
    [ValidatePattern('^ArchBtrfs-[A-Za-z0-9-]+$')][string]$Name = 'ArchBtrfs-Clean',
    [string]$Base = (Join-Path (Split-Path $PSScriptRoot) 'wsl-arch-btrfs-labs'),
    [switch]$TestFailureAfterPrepare,
    [switch]$Apply
)
. "$PSScriptRoot/scripts/host.ps1"
if ($Name -eq 'ArchBtrfs-Lab') { throw 'Manual experiment is reserved' }
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'An x64 Windows process is required' }
$Base = [IO.Path]::GetFullPath($Base)
$linuxBase = Get-GuestPath $Base
$linuxRepo = Get-GuestPath $PSScriptRoot
$path = Join-Path $Base ($Name.Substring(10))
if ($path -eq $Base) { throw 'Empty distro directory' }
$manifest = Join-Path $Base "$Name.json"
$marker = Join-Path $Base "enable-$Name"
$archive = Join-Path $Base "$Name-preboot.tar"
foreach ($f in $Base,$path,$manifest,$marker,$archive) { Assert-PlainPath $f }
Write-Host "Target: $Name at $path (new dedicated Debian + 8 GiB raw Arch image)"
Write-Host 'Risk: creates/configures this registration; activation restarts this target only.'
Write-Host 'Recovery: preserve preboot archive and arch.img; disable the target enable marker for Debian rescue.'
if (!$Apply) { Write-Host 'DRY RUN: add -Apply after approving the target'; return }
[IO.Directory]::CreateDirectory($Base) | Out-Null
$lockPath = Join-Path $Base "$Name.lock"
Assert-PlainPath $lockPath
$lock = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
$log = Join-Path $Base "$Name-$(Get-Date -Format yyyyMMdd-HHmmss)-$PID.log"
try {
    Start-Transcript -LiteralPath $log | Out-Null
    $script:LabNativeLog="$log.native.log"
    if (Test-Path -LiteralPath $manifest) {
        $state = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
        Assert-ManagedRegistration $state $Name $path
        $instance = ([guid]$state.Instance).ToString()
    } else {
        if ((Get-Registration $Name) -or (Test-Path -LiteralPath $path) -or
            (Test-Path -LiteralPath $marker) -or (Test-Path -LiteralPath $archive)) { throw 'Name or destination occupied' }
        if ((Get-PSDrive C).Free -lt 14GB) { throw 'Allow 14 GiB of free space on C:' }
        $instance = [guid]::NewGuid().ToString()
    }
    $inputs = Join-Path $Base 'inputs'
    $packages = Join-Path $inputs 'packages'
    Assert-PlainPath $packages
    [IO.Directory]::CreateDirectory($packages) | Out-Null
    Get-VerifiedInput "$inputs/Debian.wsl" '5ec7dc68216e75d1d4d4761474e99d8461a98d316537110314b137122a879e0f' 'https://salsa.debian.org/debian/WSL/-/jobs/9606244/artifacts/raw/Debian_WSL_AMD64_v1.26.0.0.wsl'
    Get-VerifiedInput "$inputs/archlinux.wsl" 'd2ef183f58cd65bfce52d5a122fe4936f7f2ac0af6b1b427681afd28d1f64b17' 'https://fastly.mirror.pkgbuild.com/wsl/2026.10.01.179549/archlinux-2026.10.01.179549.wsl'
    foreach ($line in Get-Content "$PSScriptRoot/scripts/arch-packages.sha256") {
        if ($line -notmatch '^([0-9a-f]{64})  (([a-z0-9@+._-]+)-[^-]+-[^-]+-(x86_64|any)\.pkg\.tar\.zst(?:\.sig)?)$') { throw "Invalid package entry: $line" }
        $hash=$Matches[1]; $file=$Matches[2]; $pkg=$Matches[3]
        $winFile=$file.Replace([char]':',[char]0xf03a)
        Get-VerifiedInput "$packages/$winFile" $hash "https://archive.archlinux.org/packages/$($pkg[0])/$pkg/$([uri]::EscapeDataString($file))"
    }
    if (!(Test-Path -LiteralPath $manifest)) {
        Invoke-LabWsl --import $Name $path "$inputs/Debian.wsl" --version 2
        $reg = Get-Registration $Name
        $state = [pscustomobject]@{Name=$Name;Path=$path;Instance=$instance;Registration=$reg.PSChildName}
        Assert-ManagedRegistration $state $Name $path
        [IO.File]::WriteAllText($manifest,($state | ConvertTo-Json))
    }
    if (!(Test-Path -LiteralPath "$archive.sha256")) {
        if (Test-Path -LiteralPath $archive) { throw 'Unverified backup exists. Inspect before retrying.' }
        Invoke-LabWsl --export $Name $archive
        $digest=(Get-FileHash -LiteralPath $archive).Hash
        [IO.File]::WriteAllText("$archive.sha256",$digest)
    } elseif (!(Test-Path -LiteralPath $archive) -or
        (Get-FileHash -LiteralPath $archive).Hash -ne [IO.File]::ReadAllText("$archive.sha256").Trim()) {
        throw 'Backup missing or checksum mismatch'
    }
    $fs = (Invoke-LabWsl -d $Name -u root --cd / --exec /usr/bin/findmnt -nro FSTYPE /).Trim()
    if ($fs -eq 'ext4') {
        if (Test-Path -LiteralPath $marker) { throw 'Activation requested but root is ext4. Inspect guest boot.log.' }
        Invoke-LabWsl -d $Name -u root --cd / --exec /bin/bash "$linuxRepo/scripts/prepare.sh" $linuxRepo "$linuxBase/inputs" $Name $instance (Get-GuestPath $marker) --apply
        if ($TestFailureAfterPrepare) { throw 'Injected interruption after prepare, before activation' }
        [IO.File]::Open($marker,'CreateNew','Write','None').Dispose()
        Invoke-LabWsl --terminate $Name
    } elseif ($fs -ne 'btrfs') { throw "Unexpected root filesystem: $fs" }
    Invoke-LabWsl -d $Name -u root --cd / --exec /bin/bash "$linuxRepo/scripts/finish.sh" $linuxRepo "$linuxBase/inputs" $instance --apply
    Invoke-LabWsl -d $Name -u root --cd / --exec /bin/bash "$linuxRepo/tests/root.sh" $instance
    Write-Host "Verified Arch/Btrfs: $Name"
} finally {
    $lock.Dispose()
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
