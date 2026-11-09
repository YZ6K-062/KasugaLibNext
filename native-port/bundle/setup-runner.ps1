# setup-runner.ps1 - one-shot environment setup + GitHub Actions runner install
# for the Surface backup machine.
#
# Run in an ELEVATED PowerShell (Run as Administrator):
#   powershell -ExecutionPolicy Bypass -File .\setup-runner.ps1 -Token <TOKEN>
#
# What it does (idempotent, safe to re-run):
#   1. checks OS / admin / disk
#   2. installs Git, Python 3, CMake, Ninja (winget, falling back to direct download)
#   3. copies llvm-mingw-xp from this share to a local folder (or keeps it on the share)
#   4. downloads the latest actions-runner, configures it with your labels
#   5. optionally installs it as a Windows service
#
# It does NOT need QEMU: the experimental CI jobs that run on Windows only
# cross-compile with llvm-mingw. QEMU is used by the Linux jobs for runtime
# smoke tests, and those run on the Debian build host.
#
# Get a registration token:
#   Repo -> Settings -> Actions -> Runners -> New self-hosted runner
#   (copy the token from the configure command it shows; it expires in ~1h)
# Or with a PAT that has admin:org/repo scope, pass -Pat instead of -Token and
# the script will mint a registration token via the API.

[CmdletBinding()]
param(
    [string]$Token,
    [string]$Pat,
    [string]$RepoUrl = 'https://github.com/YZ6K-062/KasugaLibNext',
    [string]$RunnerName = $env:COMPUTERNAME,
    [string]$Labels = 'xp-toolchain',
    [string]$RunnerRoot = 'C:\actions-runner',
    [string]$MingwXpPath = 'C:\llvm-mingw-xp',
    [string]$WorkFolder = 'C:\actions-runner\_work',
    [switch]$InstallService,
    [switch]$SkipTools,
    [switch]$KeepMingwOnShare,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
try {
    # Make the console emit UTF-8 so a non-ASCII share name is readable in the
    # output. Without this a Chinese Windows console (code page 936) mangles it.
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$ProgressPreference = 'SilentlyContinue'

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "  $m" }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; throw $m }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LatestRunnerVersion {
    try {
        $r = Invoke-RestMethod -Uri 'https://api.github.com/repos/actions/runner/releases/latest' `
            -Headers @{ 'User-Agent' = 'kasuga-runner-setup' } -TimeoutSec 60
        return $r.tag_name.TrimStart('v')
    } catch {
        Warn "could not query latest runner version ($($_.Exception.Message)); falling back to 2.330.0"
        return '2.330.0'
    }
}

function Ensure-WingetPackage([string]$Id, [string]$Probe) {
    if (Get-Command $Probe -ErrorAction SilentlyContinue) { Ok "$Probe already present"; return $true }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { return $false }
    Info "installing $Id via winget ..."
    & winget install --id $Id -e --source winget --accept-package-agreements --accept-source-agreements --silent 2>&1 |
        Out-Host
    return [bool](Get-Command $Probe -ErrorAction SilentlyContinue)
}

function Get-RegistrationToken {
    param([string]$RepoUrl, [string]$Pat, [string]$Token)
    if ($Token) { return $Token }
    if (-not $Pat) { return $null }
    # https://github.com/OWNER/REPO  ->  OWNER/REPO
    $slug = ($RepoUrl -replace '^https?://github\.com/', '') -replace '\.git$', ''
    Info "minting registration token for $slug"
    $resp = Invoke-RestMethod -Method Post `
        -Uri "https://api.github.com/repos/$slug/actions/runners/registration-token" `
        -Headers @{ Authorization = "Bearer $Pat"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'kasuga-runner-setup' } `
        -TimeoutSec 60
    return $resp.token
}

# ---------------------------------------------------------------------------
Step 'Preflight'
if (-not (Test-Admin)) { Fail 'Run this script from an elevated (Administrator) PowerShell.' }
Ok 'administrator'

$os = Get-CimInstance Win32_OperatingSystem
$ramGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
Info ("{0} build {1} / {2} cores / {3} GB RAM" -f $os.Caption, $os.BuildNumber, $cores, $ramGb)

$drive = (Get-PSDrive -Name $RunnerRoot.Substring(0,1)).Free / 1GB
Info ("free space on {0}: {1:N1} GB" -f $RunnerRoot.Substring(0,2), $drive)
if ($drive -lt 8) { Fail "at least 8 GB free is required on $($RunnerRoot.Substring(0,2)); found $([math]::Round($drive,1)) GB" }
Ok 'disk space'

if ($ramGb -lt 6) { Warn "only $ramGb GB RAM; heavy Gradle jobs may thrash. Native-only jobs are fine." }

if ($WhatIf) {
    Warn 'WhatIf set: stopping after preflight'
    return
}

# ---------------------------------------------------------------------------
if (-not $SkipTools) {
    Step 'Build tools'
    $haveGit = Ensure-WingetPackage 'Git.Git' 'git'
    if (-not $haveGit) { Warn 'git missing. Install Git for Windows manually: https://git-scm.com/download/win' }

    $havePy = Ensure-WingetPackage 'Python.Python.3.12' 'python'
    if (-not $havePy) { Warn 'python missing. Install Python 3: https://www.python.org/downloads/windows/' }

    $haveCm = Ensure-WingetPackage 'Kitware.CMake' 'cmake'
    if (-not $haveCm) { Warn 'cmake missing. Install CMake: https://cmake.org/download/' }

    $haveNj = Ensure-WingetPackage 'Ninja-build.Ninja' 'ninja'
    if (-not $haveNj) { Warn 'ninja missing (CMake can fall back to MinGW Makefiles)' }
} else {
    Step 'Build tools (skipped)'
}

# ---------------------------------------------------------------------------
Step 'llvm-mingw-xp toolchain'
$shareMingw = Join-Path $PSScriptRoot 'llvm-mingw-xp'
if ($KeepMingwOnShare) {
    if (Test-Path $shareMingw) {
        $MingwXpPath = $shareMingw
        Ok "using toolchain directly from the share: $MingwXpPath"
        Warn 'a UNC toolchain path is slower; drop -KeepMingwOnShare to copy locally'
    } else {
        Warn "share toolchain not found at $shareMingw"
    }
} else {
    if (Test-Path (Join-Path $MingwXpPath 'bin\x86_64-w64-mingw32-clang.exe')) {
        Ok "already installed: $MingwXpPath"
    } elseif (Test-Path $shareMingw) {
        Info "copying toolchain from the share to $MingwXpPath (about 514 MB) ..."
        New-Item -ItemType Directory -Force -Path $MingwXpPath | Out-Null
        Copy-Item -Path (Join-Path $shareMingw '*') -Destination $MingwXpPath -Recurse -Force
        if (Test-Path (Join-Path $MingwXpPath 'bin\x86_64-w64-mingw32-clang.exe')) {
            Ok "installed: $MingwXpPath"
        } else {
            Warn "copy finished but clang.exe is missing under $MingwXpPath"
        }
    } else {
        Warn "toolchain not found on the share ($shareMingw) and not at $MingwXpPath"
        Info 'download: https://github.com/mstorsjo/llvm-mingw/releases (msvcrt, x86_64 zip)'
    }
}
# Persist as a machine-wide variable so the CI job can point MINGW_ROOT at it.
if (Test-Path (Join-Path $MingwXpPath 'bin\x86_64-w64-mingw32-clang.exe')) {
    [Environment]::SetEnvironmentVariable('MINGW_ROOT_XP', $MingwXpPath, 'Machine')
    Ok "machine variable MINGW_ROOT_XP=$MingwXpPath"
}

# ---------------------------------------------------------------------------
Step 'Actions runner'
$regToken = Get-RegistrationToken -RepoUrl $RepoUrl -Pat $Pat -Token $Token
if (-not $regToken) {
    Warn 'no -Token and no -Pat supplied.'
    Info 'Environment setup above is complete. To finish registration either:'
    Info '  a) re-run with -Token <registration token from GitHub Settings > Actions > Runners>'
    Info '  b) or run these by hand:'
    Info "     cd $RunnerRoot"
    Info "     .\config.cmd --url $RepoUrl --token <TOKEN> --name $RunnerName --labels $Labels --work $WorkFolder --unattended"
    Info "     .\run.cmd            (interactive)   or   .\svc.cmd install && .\svc.cmd start"
    return
}

New-Item -ItemType Directory -Force -Path $RunnerRoot | Out-Null
Set-Location $RunnerRoot

if (Test-Path (Join-Path $RunnerRoot 'config.cmd')) {
    Ok 'runner package already present'
} else {
    $ver = Get-LatestRunnerVersion
    $zip = "actions-runner-win-x64-$ver.zip"
    $url = "https://github.com/actions/runner/releases/download/v$ver/$zip"
    Info "downloading actions-runner $ver ..."
    Invoke-WebRequest -Uri $url -OutFile (Join-Path $RunnerRoot $zip) -TimeoutSec 600
    # The release ships with a .sha256 file; verify before unpacking.
    try {
        $sumUrl = "$url.sha256"
        $expected = (Invoke-WebRequest -Uri $sumUrl -TimeoutSec 60).Content.Trim().Split(' ')[0]
        $actual = (Get-FileHash -Algorithm SHA256 (Join-Path $RunnerRoot $zip)).Hash.ToLower()
        if ($expected -and ($actual -ne $expected.ToLower())) { Fail "checksum mismatch for $zip" }
        Ok "checksum verified ($($actual.Substring(0,16))...)"
    } catch {
        Warn "checksum check skipped: $($_.Exception.Message)"
    }
    Info 'extracting ...'
    Expand-Archive -Path (Join-Path $RunnerRoot $zip) -DestinationPath $RunnerRoot -Force
    Remove-Item (Join-Path $RunnerRoot $zip) -Force
    Ok 'runner unpacked'
}

if (Test-Path (Join-Path $RunnerRoot '.runner')) {
    Ok 'runner already configured; skipping config.cmd'
} else {
    Info 'configuring runner ...'
    & (Join-Path $RunnerRoot 'config.cmd') --unattended --url $RepoUrl --token $regToken `
        --name $RunnerName --labels $Labels --work $WorkFolder --replace 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { Fail "config.cmd failed with exit code $LASTEXITCODE" }
    Ok 'runner configured'
}

if ($InstallService) {
    if (Get-Service 'actions.runner.*' -ErrorAction SilentlyContinue) {
        Ok 'service already installed'
    } else {
        Info 'installing runner as a Windows service ...'
        & (Join-Path $RunnerRoot 'svc.cmd') install 2>&1 | Out-Host
        & (Join-Path $RunnerRoot 'svc.cmd') start 2>&1 | Out-Host
        Ok 'service installed and started'
    }
} else {
    Info "to install as a service: cd $RunnerRoot; .\svc.cmd install; .\svc.cmd start"
}

Step 'Done'
Info "runner : $RunnerName"
Info "labels : self-hosted, Windows, $Labels"
Info "repo   : $RepoUrl"
Info 'check GitHub Settings > Actions > Runners for the Idle state'
