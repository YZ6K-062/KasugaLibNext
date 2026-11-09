# cleanup-share.ps1
#
# Remove the runner copy and installer payloads from the SMB share once the
# runner has been migrated to the local disk.
#
# SAFETY
#   - Dry run unless you pass -Execute.
#   - Refuses to run until it can confirm a configured local runner exists.
#   - Deletions go to the Recycle Bin when the shell API is available, with a
#     direct-delete fallback.
#
# ENCODING
#   Saved as UTF-8 with BOM: Windows PowerShell 5.1 otherwise decodes a
#   BOM-less UTF-8 script with the system ANSI code page (GBK on a Chinese
#   Windows install), which corrupts non-ASCII path literals. The script is
#   also pure ASCII and auto-detects the share.
#
# Usage (ELEVATED):
#   powershell -ExecutionPolicy Bypass -File .\cleanup-share.ps1
#   powershell -ExecutionPolicy Bypass -File .\cleanup-share.ps1 -Execute

[CmdletBinding()]
param(
    [string]$ShareRunner = '',
    [string]$LocalRunner = 'C:\actions-runner',
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
try {
    # Make the console emit UTF-8 so a non-ASCII share name is readable in the
    # output. Without this a Chinese Windows console (code page 936) mangles it.
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

function Info($m) { Write-Host "  $m" }
function Ok($m)   { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }

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
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Root -like '\\*') {
            $cand = Join-Path $d.Root 'runner'
            if (Test-RunnerHome $cand) { return $cand }
            foreach ($sub in (Get-ChildItem -LiteralPath $d.Root -Directory -ErrorAction SilentlyContinue)) {
                $c2 = Join-Path $sub.FullName 'runner'
                if (Test-RunnerHome $c2) { return $c2 }
            }
        }
    }
    foreach ($k in (Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
        $rp = (Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue).RemotePath
        if ($rp) {
            $cand = Join-Path $rp 'runner'
            if (Test-RunnerHome $cand) { return $cand }
        }
    }
    return $null
}

Write-Host "=== Precheck ===" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath (Join-Path $LocalRunner '.runner'))) {
    Write-Host "  [FAIL] no configured runner at $LocalRunner" -ForegroundColor Red
    Write-Host "         run migrate-runner-to-local.ps1 first, then re-run this." -ForegroundColor Red
    exit 1
}
$j = Get-Content -LiteralPath (Join-Path $LocalRunner '.runner') -Raw | ConvertFrom-Json
Ok "local runner present: $($j.agentName) (agentId $($j.agentId))"

$ShareRunner = Resolve-ShareRunner $ShareRunner
if (-not $ShareRunner) {
    Write-Host '  [FAIL] could not locate the runner folder on the share.' -ForegroundColor Red
    Write-Host '         Pass it explicitly: -ShareRunner <\\host\share\runner>' -ForegroundColor Red
    exit 1
}
Ok "share runner: $ShareRunner"

$svc = Get-Service -Name 'actions.runner*' -ErrorAction SilentlyContinue
if ($svc) { foreach ($s in $svc) { Info "service $($s.Name): $($s.Status)" } }

# ------------------------------------------------------------- inventory ----
Write-Host "`n=== What would be removed from the share ===" -ForegroundColor Cyan

$targets = @()
foreach ($d in @('bin', 'externals', '_work', '_diag', 'llvm-mingw-xp')) {
    $p = Join-Path $ShareRunner $d
    if (Test-Path -LiteralPath $p) {
        $mb = [math]::Round(((Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum / 1MB), 0)
        $targets += [pscustomobject]@{ Path = $p; Kind = 'dir'; Size = "$mb MB" }
    }
}
foreach ($f in @('.credentials', '.credentials_rsaparams', '.runner', 'config.cmd',
                 'run.cmd', 'run.sh', 'run-helper.cmd', 'run-helper.sh',
                 'run-helper.cmd.template', 'run-helper.sh.template',
                 'run-helper-powershell.cmd', 'run-helper-powershell.ps1',
                 '.env', '.path')) {
    $p = Join-Path $ShareRunner $f
    if (Test-Path -LiteralPath $p) {
        $targets += [pscustomobject]@{ Path = $p; Kind = 'file'; Size = '{0:N0} B' -f (Get-Item -LiteralPath $p).Length }
    }
}
foreach ($z in @('packages\actions-runner-win-x64-2.338.2.zip', 'packages\llvm-mingw-xp.zip')) {
    $p = Join-Path $ShareRunner $z
    if (Test-Path -LiteralPath $p) {
        $targets += [pscustomobject]@{ Path = $p; Kind = 'zip'; Size = '{0:N0} MB' -f ((Get-Item -LiteralPath $p).Length / 1MB) }
    }
}
$targets | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("  {0} item(s) would be removed." -f ($targets | Measure-Object).Count) -ForegroundColor Yellow
Write-Host "`n  KEPT on the share: scripts\, packages\, logs\, README-runner.txt" -ForegroundColor Green

if (-not $Execute) {
    Write-Host "`nDry run only. Re-run with -Execute to actually remove them." -ForegroundColor Cyan
    exit 0
}

# ---------------------------------------------------------------- delete ----
Write-Host "`n=== Deleting ===" -ForegroundColor Cyan
$recycle = $false
try {
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    $recycle = $true
} catch {
    Warn 'Recycle Bin API unavailable; falling back to direct delete'
}

$fail = 0
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t.Path)) { continue }
    try {
        if ($t.Kind -eq 'dir') {
            if ($recycle) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                    $t.Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
            } else {
                Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop
            }
        } else {
            if ($recycle) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $t.Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
            } else {
                Remove-Item -LiteralPath $t.Path -Force -ErrorAction Stop
            }
        }
        Ok "removed $($t.Path)"
    } catch {
        Write-Host "  [FAIL] $($t.Path): $($_.Exception.Message)" -ForegroundColor Red
        $fail++
    }
}

foreach ($d in @('packages', 'logs')) {
    $p = Join-Path $ShareRunner $d
    if ((Test-Path -LiteralPath $p) -and -not (Get-ChildItem -LiteralPath $p -Force)) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n=== Remaining on the share ===" -ForegroundColor Cyan
Get-ChildItem -LiteralPath $ShareRunner -Force |
    Select-Object Mode, Name, @{n='MB';e={ if ($_.PSIsContainer) {''} else {[math]::Round($_.Length/1MB,2)} }} |
    Format-Table -AutoSize | Out-String | Write-Host
if ($fail -eq 0) { Write-Host 'Cleanup complete.' -ForegroundColor Green }
else { Write-Host "$fail item(s) could not be removed - see messages above." -ForegroundColor Yellow }
