# migrate-runner-to-local.ps1
#
# Move the GitHub Actions runner OFF the SMB share and onto the local disk.
#
# WHY
#   The runner home is currently a network share. Two real problems:
#     1. .credentials holds the runner's RSA private key in plain text. Anyone
#        who can read that share can impersonate the runner against the repo.
#     2. _work (checkout + build dir) lives on the network, so every job pays
#        SMB latency for git checkout, CMake and file IO.
#   Moving the whole runner home keeps the same agent identity (agentId lives
#   in .runner / .credentials), so NO new registration token is needed.
#
# ALSO
#   Installs the Legacy-Windows cross toolchain from packages\llvm-mingw-xp.zip
#   and publishes MINGW_ROOT_XP machine-wide, which the self-hosted-xp
#   workflow job reads.
#
# NOTE ON ENCODING
#   This file is saved as UTF-8 WITH BOM on purpose: Windows PowerShell 5.1
#   decodes BOM-less UTF-8 scripts using the system ANSI code page (GBK on a
#   Chinese Windows install), which corrupts non-ASCII path literals.
#   The script also avoids non-ASCII entirely and auto-detects the share, so
#   it works even if the BOM is lost in transit.
#
# Usage (run ELEVATED on the machine that hosts the share):
#   powershell -ExecutionPolicy Bypass -File .\migrate-runner-to-local.ps1
#   powershell -ExecutionPolicy Bypass -File .\migrate-runner-to-local.ps1 -WhatIf

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ShareRunner = '',
    [string]$LocalRunner = 'C:\actions-runner',
    [string]$MingwDir     = 'C:\llvm-mingw-xp'
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

# ------------------------------------------------------- share discovery ----
function Test-RunnerHome([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $p '.runner'))
}

function Resolve-ShareRunner([string]$explicit) {
    if (Test-RunnerHome $explicit) { return $explicit }
    if ($explicit) { Write-Host "  [warn] '$explicit' has no .runner, looking further" }

    if (Test-RunnerHome $env:KASUGA_SHARE_RUNNER) { return $env:KASUGA_SHARE_RUNNER }
    # The script may itself live inside the runner folder on the share
    # (\<host>\<share>\runner\scripts\...), in which case the runner home
    # is simply the parent directory.
    if ($PSScriptRoot) {
        $cand = Split-Path -Parent $PSScriptRoot
        if (Test-RunnerHome $cand) { return $cand }
    }

    # Mapped network drives (SMB drives mapped by Explorer / New-PSDrive).
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Root -like '\\*') {
            $cand = Join-Path $d.Root 'runner'
            if (Test-RunnerHome $cand) { return $cand }
        }
    }
    # Persistent network mappings in the registry.
    foreach ($k in (Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
        $rp = (Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue).RemotePath
        if ($rp) {
            $cand = Join-Path $rp 'runner'
            if (Test-RunnerHome $cand) { return $cand }
        }
    }
    # Any visible \\host\share roots we can enumerate.
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Root -like '\\*') {
            foreach ($sub in (Get-ChildItem -LiteralPath $d.Root -Directory -ErrorAction SilentlyContinue)) {
                $cand = Join-Path $sub.FullName 'runner'
                if (Test-RunnerHome $cand) { return $cand }
            }
        }
    }
    return $null
}

Step 'Locating the runner on the share'
$ShareRunner = Resolve-ShareRunner $ShareRunner
if (-not $ShareRunner) {
    Write-Host '  [FAIL] could not find a runner home (a folder containing .runner).' -ForegroundColor Red
    Write-Host '         Pass it explicitly:  -ShareRunner <\\host\share\runner>'
    Write-Host '         or set:              $env:KASUGA_SHARE_RUNNER = <\\host\share\runner>'
    exit 1
}
Ok "runner home: $ShareRunner"

$id = Get-Content -LiteralPath (Join-Path $ShareRunner '.runner') -Raw | ConvertFrom-Json
Info "agent : $($id.agentName) (agentId $($id.agentId), pool $($id.poolName))"
Info "repo  : $($id.gitHubUrl)"

# ------------------------------------------------------------------- stop ----
Step 'Stopping the runner'
$svc = Get-Service -Name 'actions.runner*' -ErrorAction SilentlyContinue
if ($svc) {
    foreach ($s in $svc) {
        Info "stopping service $($s.Name) [$($s.Status)]"
        if ($s.Status -eq 'Running') { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue }
    }
    Ok 'services stopped'
} else {
    Ok 'no actions.runner* service (runner probably runs from a console)'
}
$procs = Get-Process -Name 'Runner.Listener', 'Runner.Worker' -ErrorAction SilentlyContinue
if ($procs) {
    foreach ($p in $procs) { Info "stopping $($p.ProcessName) (pid $($p.Id))"; $p | Stop-Process -Force -ErrorAction SilentlyContinue }
    Ok 'runner processes stopped'
} else {
    Ok 'no runner process running'
}

# ------------------------------------------------------------------ copy ----
Step "Copying runner to $LocalRunner"
New-Item -ItemType Directory -Force -Path $LocalRunner | Out-Null
$items = @('bin', 'externals', '_work', '_diag', '.runner', '.credentials',
           '.credentials_rsaparams', '.env', '.path', 'config.cmd', 'config.sh',
           'run.cmd', 'run.sh', 'run-helper.cmd', 'run-helper.sh',
           'run-helper.cmd.template', 'run-helper.sh.template',
           'run-helper-powershell.cmd', 'run-helper-powershell.ps1', 'worker.js')
foreach ($it in $items) {
    $src = Join-Path $ShareRunner $it
    if (-not (Test-Path -LiteralPath $src)) { continue }
    $dst = Join-Path $LocalRunner $it
    if ($PSCmdlet.ShouldProcess($dst, 'copy from share')) {
        if ((Get-Item -LiteralPath $src).PSIsContainer) {
            Copy-Item -LiteralPath $src -Destination $LocalRunner -Recurse -Force
        } else {
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }
}
Ok "runner copied to $LocalRunner"

$localJson = Join-Path $LocalRunner '.runner'
if (Test-Path -LiteralPath $localJson) {
    $j = Get-Content -LiteralPath $localJson -Raw | ConvertFrom-Json
    $j.workFolder = '_work'      # relative -> resolves under the LOCAL folder
    $j | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $localJson -Encoding UTF8
    Ok 'workFolder pinned to the local _work'
}

# ------------------------------------------------------------------ mingw ----
Step 'Installing the Legacy Windows cross toolchain'
$clangName = 'bin\x86_64-w64-mingw32-clang.exe'
$zip = Join-Path $ShareRunner 'packages\llvm-mingw-xp.zip'
if (Test-Path -LiteralPath (Join-Path $MingwDir $clangName)) {
    Ok "already installed: $MingwDir"
} elseif (Test-Path -LiteralPath $zip) {
    Info "extracting $zip -> $MingwDir (about 500 MB)"
    if ($PSCmdlet.ShouldProcess($MingwDir, 'extract toolchain archive')) {
        New-Item -ItemType Directory -Force -Path $MingwDir | Out-Null
        # Expand-Archive does NOT support -WhatIf (it dies with
        # IndexOutOfRange) and cannot overwrite existing files on .NET
        # Framework, so extract entry by entry with the .NET API instead.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            foreach ($entry in $archive.Entries) {
                $target = Join-Path $MingwDir $entry.FullName
                if ([string]::IsNullOrEmpty($entry.Name)) {
                    New-Item -ItemType Directory -Force -Path $target | Out-Null
                    continue
                }
                $parent = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Force -Path $parent | Out-Null
                }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        } finally { $archive.Dispose() }
    }
    $inner = Get-ChildItem -LiteralPath $MingwDir -Directory -ErrorAction SilentlyContinue |
             Where-Object { Test-Path (Join-Path $_.FullName $clangName) } | Select-Object -First 1
    if ($inner) {
        Info "flattening $($inner.Name) -> $MingwDir"
        Get-ChildItem -LiteralPath $inner.FullName -Force | ForEach-Object {
            if ($PSCmdlet.ShouldProcess($_.FullName, 'move up one level')) {
                Move-Item -LiteralPath $_.FullName -Destination $MingwDir -Force
            }
        }
        if ($PSCmdlet.ShouldProcess($inner.FullName, 'remove wrapper folder')) {
            Remove-Item -LiteralPath $inner.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path (Join-Path $MingwDir $clangName)) { Ok "installed: $MingwDir" }
    elseif (-not $PSCmdlet.ShouldProcess($MingwDir, 'x')) {
        Info "(dry run: archive would be extracted to $MingwDir)"
    }
    else { Warn "clang.exe not found under $MingwDir - check the zip layout" }
} else {
    Warn "llvm-mingw-xp.zip not found at $zip"
}

if (Test-Path (Join-Path $MingwDir $clangName)) {
    [Environment]::SetEnvironmentVariable('MINGW_ROOT_XP', $MingwDir, 'Machine')
    Ok "machine variable MINGW_ROOT_XP=$MingwDir"
    & (Join-Path $MingwDir $clangName) --version | Select-Object -First 1 | ForEach-Object { Info "  $_" }
}

# ---------------------------------------------------------------- service ----
Step 'Installing the runner as a local service'
$svcCmd = Join-Path $LocalRunner 'svc.cmd'
if (Test-Path -LiteralPath $svcCmd) {
    Push-Location $LocalRunner
    try {
        & .\svc.cmd uninstall 2>&1 | Out-Null   # drop any previous registration
        & .\svc.cmd install 2>&1 | Out-Host
        & .\svc.cmd start  2>&1 | Out-Host
        Ok 'service installed and started'
    } catch {
        Warn "service install failed: $($_.Exception.Message)"
        Info "start manually:  cd $LocalRunner ; .\run.cmd"
    } finally { Pop-Location }
} else {
    Warn "svc.cmd not found in $LocalRunner"
}

Step 'Verification'
$allOk = $true
foreach ($f in @('.runner', '.credentials', 'bin\Runner.Listener.exe', 'bin\Runner.Worker.exe')) {
    $p = Join-Path $LocalRunner $f
    if (Test-Path -LiteralPath $p) { Ok "present: $f" } else { Warn "MISSING: $f"; $allOk = $false }
}
$svcNow = Get-Service -Name 'actions.runner*' -ErrorAction SilentlyContinue
if ($svcNow) { foreach ($s in $svcNow) { Info "service $($s.Name): $($s.Status)" } }
else { Warn 'no actions.runner* service - run .\run.cmd manually' }
if (-not $allOk) { Write-Host "`nSome files are missing - check the copy output above." -ForegroundColor Yellow }

Write-Host @"

Done. The runner now lives on the local disk.

  runner home : $LocalRunner
  work folder : $LocalRunner\_work
  toolchain  : $MingwDir  (MINGW_ROOT_XP)
  old copy   : $ShareRunner  (still there; remove with cleanup-share.ps1)

Check GitHub -> Settings -> Actions -> Runners: same name, should be Idle again.
The IA-64 job needs a SEPARATE Linux runner inside WSL - see setup-wsl-runner.sh.
"@ -ForegroundColor Green
