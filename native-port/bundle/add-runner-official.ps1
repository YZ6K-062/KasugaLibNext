#Requires -Version 5.1
<#
.SYNOPSIS
  GitHub official "New self-hosted runner" flow, repaired for KasugaLibNext.

.DESCRIPTION
  Reproduces the commands on GitHub's "New self-hosted runner" page, with
  these fixes (all found by actually running the copied text):

    * The web page copy glues comments onto the previous command, leaves a
      stray "Copied!" token in the hash-check line, and appends "# Run it!"
      directly to --token. Pasting it verbatim cannot work. This script
      restores the real command lines.
    * Installs to a LOCAL disk folder (C:\actions-runner), never onto the SMB
      share. .credentials is a plaintext RSA private key, and _work on a
      network drive makes every job's checkout/CMake IO go over SMB.
    * Reuses the already-verified zip in <share>\packages when present
      (offline friendly), otherwise downloads the official release.
    * Uses tar.exe / Expand-Archive instead of Add-Type. Add-Type is blocked
      in managed environments and is unnecessary on Windows 10+.
    * Adds the "xp-toolchain" label that the experimental CI workflow needs.
      The page's "runs-on: self-hosted" example is too broad for this repo.
    * UTF-8 with BOM and ASCII-only source. Windows PowerShell 5.1 decodes
      BOM-less UTF-8 with the ANSI code page, which garbles non-ASCII paths.

  The registration token is NEVER stored in this file. Pass it with -Token.
  Registration tokens expire after one hour.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\add-runner-official.ps1 -WhatIf
  powershell -ExecutionPolicy Bypass -File .\add-runner-official.ps1 -Token <token> -RunAsService
  powershell -ExecutionPolicy Bypass -File .\add-runner-official.ps1 -VerifyOnly -LocalRunner C:\verify
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Token        = '',
    [string]$RepoUrl      = 'https://github.com/YZ6K-062/KasugaLibNext',
    [string]$LocalRunner  = 'C:\actions-runner',
    [string]$Labels       = 'xp-toolchain',
    [string]$RunnerName   = $env:COMPUTERNAME,
    [string]$ShareRunner  = '',
    [switch]$RunAsService,
    [switch]$Replace,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
# The config wrapper invokes a secondary Windows shell to unblock downloaded
# files. Some managed shells strip System32 from PATH, so restore it first.
$sys32 = Join-Path $env:SystemRoot 'System32'
if ($env:PATH -notlike "*$sys32*") { $env:PATH = "$sys32;$env:PATH" }

function Info([string]$m) { Write-Host "  [..] $m" -ForegroundColor Cyan }
function Ok  ([string]$m) { Write-Host "  [ok] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Fail([string]$m) { throw $m }

$ZipName   = 'actions-runner-win-x64-2.338.2.zip'
$Sha256    = 'a1f17aa987fc8158bc7521d284912267a0d01b7c2c4684b33c86783b5e8221cc'
$Url       = "https://github.com/actions/runner/releases/download/v2.338.2/$ZipName"

function Test-RunnerHome([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $p '.runner')) -or
           (Test-Path -LiteralPath (Join-Path $p (Join-Path 'packages' $ZipName)))
}

function Resolve-ShareRunner {
    if (-not [string]::IsNullOrWhiteSpace($ShareRunner)) { return $ShareRunner }
    if ($env:KASUGA_SHARE_RUNNER) { return $env:KASUGA_SHARE_RUNNER }
    # When this script lives in <share>\runner\scripts\, the parent of
    # $PSScriptRoot is the runner home. No non-ASCII literal is needed.
    if ($PSScriptRoot) {
        $cand = Split-Path -Parent $PSScriptRoot
        if (Test-RunnerHome $cand) { return $cand }
    }
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.DisplayRoot -and (Test-RunnerHome $d.Root)) { return $d.Root }
    }
    try {
        foreach ($k in Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue) {
            $rp = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).RemotePath
            if ($rp -and (Test-RunnerHome (Join-Path $rp 'runner'))) {
                return (Join-Path $rp 'runner')
            }
        }
    } catch { }
    return ''
}

Write-Host ''
Write-Host '=== GitHub official runner setup (repaired) ===' -ForegroundColor White

# ---- 1. Locate the share and the runner package --------------------------
$share = Resolve-ShareRunner
if ($share) { Ok "share runner home: $share" }
else        { Warn 'share not auto-detected; will download the package instead' }

$zip = ''
if ($share) {
    $candidate = Join-Path (Join-Path $share 'packages') $ZipName
    if (Test-Path -LiteralPath $candidate) { $zip = $candidate }
}

if (-not $zip) {
    $zip = Join-Path $env:TEMP $ZipName
    if (-not (Test-Path -LiteralPath $zip)) {
        Info "downloading $Url"
        if ($PSCmdlet.ShouldProcess($Url, 'download runner package')) {
            Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing
        }
    }
}
if (Test-Path -LiteralPath $zip) { Ok "package: $zip" }

# ---- 2. Official SHA256 check --------------------------------------------
if (Test-Path -LiteralPath $zip) {
    $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Sha256.ToLower()) {
        Fail "checksum mismatch: expected $Sha256 got $actual"
    }
    Ok "SHA256 matches GitHub ($($actual.Substring(0,16))...)"
}

# ---- 3. Extract to a LOCAL folder ----------------------------------------
$cfg = Join-Path $LocalRunner 'config.cmd'
if ($PSCmdlet.ShouldProcess($LocalRunner, 'extract runner package')) {
    if (-not (Test-Path -LiteralPath $zip)) { Fail "package missing: $zip" }
    New-Item -ItemType Directory -Force -Path $LocalRunner | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path -LiteralPath $tar) {
        & $tar -xf $zip -C $LocalRunner
        if ($LASTEXITCODE -ne 0) { Fail "tar.exe failed with exit $LASTEXITCODE" }
        Info 'extracted with tar.exe'
    } else {
        Expand-Archive -LiteralPath $zip -DestinationPath $LocalRunner
        Info 'extracted with Expand-Archive'
    }
    if (-not (Test-Path -LiteralPath $cfg)) { Fail "config.cmd not found in $LocalRunner" }
    Ok "runner files installed: $LocalRunner"
}

# ---- 4. Runner.Listener.exe --version (CLI sanity, no network) -----------
# Call the exe directly: the .cmd wrapper only adds an unblock step that is
# unnecessary here and needs a secondary shell on PATH.
$listener = Join-Path $LocalRunner 'bin\Runner.Listener.exe'
if (Test-Path -LiteralPath $listener) {
    if ($PSCmdlet.ShouldProcess($listener, 'query runner version')) {
        $v = & $listener --version 2>&1
        Ok "runner version: $($v | Select-Object -First 1)"
    } else {
        Info '(dry run: runner version would be checked)'
    }
}

# ---- 5. Register ---------------------------------------------------------
if ($VerifyOnly) {
    Ok 'VerifyOnly: registration skipped (no token consumed)'
    Write-Host ''
    return
}

$existing = Join-Path $LocalRunner '.runner'
if (Test-Path -LiteralPath $existing) {
    Warn ".runner already exists in $LocalRunner - this runner appears configured"
    if (-not $Replace) {
        Fail 'use -Replace to re-register, or remove the existing runner first'
    }
}

if ([string]::IsNullOrWhiteSpace($Token) -and -not $WhatIfPreference) {
    Write-Host ''
    Write-Host '  No -Token supplied. Get a fresh one from:' -ForegroundColor Yellow
    Write-Host "    $RepoUrl/settings/actions/runners/new" -ForegroundColor Yellow
    Write-Host '  Tokens expire after one hour and must not be committed.' -ForegroundColor Yellow
    Write-Host ''
    return
}

$cfgArgs = @('--unattended', '--url', $RepoUrl, '--token', $Token,
             '--name', $RunnerName, '--labels', $Labels, '--work', '_work')
if ($Replace)      { $cfgArgs += '--replace' }
if ($RunAsService) { $cfgArgs += '--runasservice' }

if ($RunAsService) {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Fail '-RunAsService requires an elevated shell' }
}

Info "registering '$RunnerName' with labels [$Labels] to $RepoUrl"
if ($PSCmdlet.ShouldProcess($RepoUrl, 'register self-hosted runner')) {
    & $cfg @cfgArgs
    if ($LASTEXITCODE -ne 0) { Fail "config.cmd failed with exit $LASTEXITCODE" }
    if (Test-Path -LiteralPath $existing) { Ok 'registered (.runner created)' }
    else { Warn 'config.cmd returned but .runner was not created - check output above' }
    if (-not $RunAsService) {
        Write-Host ''
        Write-Host '  Start it with:' -ForegroundColor White
        Write-Host "    cd $LocalRunner ; .\run.cmd" -ForegroundColor White
    }
}
Write-Host ''
