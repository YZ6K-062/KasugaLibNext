# probe.ps1 - collect environment facts from the Surface runner host.
# Writes probe-result.json next to this script and prints a short summary.
# Read-only: changes nothing on the machine.

$ErrorActionPreference = 'Continue'
try {
    # Make the console emit UTF-8 so a non-ASCII share name is readable in the
    # output. Without this a Chinese Windows console (code page 936) mangles it.
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$out = [ordered]@{}
$out.timestamp = (Get-Date).ToString('o')
$out.computer = $env:COMPUTERNAME
$out.user = $env:USERNAME

# --- OS / hardware -----------------------------------------------------------
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $out.os_caption = $os.Caption
    $out.os_version = $os.Version
    $out.os_build = $os.BuildNumber
    $out.os_arch = $os.OSArchitecture
    $out.ram_gb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
} catch { $out.os_error = "$($_.Exception.Message)" }

try {
    $cs = Get-CimInstance Win32_ComputerSystem
    $out.model = $cs.Model
    $out.manufacturer = $cs.Manufacturer
    $out.cpu_cores = $cs.NumberOfLogicalProcessors
} catch { $out.hw_error = "$($_.Exception.Message)" }

try {
    $sys = $env:SystemDrive
    $d = Get-PSDrive -Name $sys.TrimEnd(':') -ErrorAction Stop
    $out.system_drive_free_gb = [math]::Round($d.Free / 1GB, 1)
} catch { }

# --- admin rights ------------------------------------------------------------
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    $out.is_admin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $out.is_admin = $null }

# --- tools on PATH -----------------------------------------------------------
$tools = 'git','python','python3','cmake','ninja','7z','tar','curl','wsl','java','gh'
$out.tools = [ordered]@{}
foreach ($t in $tools) {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    if ($c) {
        $ver = ''
        try { $ver = (& $c.Source --version 2>&1 | Select-Object -First 1) -as [string] } catch { }
        $out.tools[$t] = [ordered]@{ path = $c.Source; version = $ver.Trim() }
    } else {
        $out.tools[$t] = $null
    }
}

# --- WSL detail --------------------------------------------------------------
try {
    $wslExe = "$env:SystemRoot\System32\wsl.exe"
    if (Test-Path $wslExe) {
        $distros = & $wslExe -l -q 2>&1
        $out.wsl_distros = @($distros | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
    } else { $out.wsl_distros = @() }
} catch { $out.wsl_error = "$($_.Exception.Message)" }

# --- virtualization (needed for a Linux runner VM) ---------------------------
try {
    $out.virtualization_firmware_enabled = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
} catch { }
try {
    $hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
    $out.hyperv_feature_state = $hv.State
} catch { $out.hyperv_feature_state = 'unknown' }
try {
    $vmpp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
    $out.vm_platform_state = $vmpp.State
} catch { $out.vm_platform_state = 'unknown' }

# --- network reachability ----------------------------------------------------
function Test-Host([string]$h, [int]$port = 443) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($h, $port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(2500) -and $c.Connected) { return $true }
        return $false
    } catch { return $false } finally { $c.Close() }
}
$out.net = [ordered]@{
    github_com    = (Test-Host 'github.com' 443)
    objects_gh    = (Test-Host 'objects.githubusercontent.com' 443)
    api_github    = (Test-Host 'api.github.com' 443)
    raw_github    = (Test-Host 'raw.githubusercontent.com' 443)
    proxy_env     = ($env:HTTP_PROXY, $env:HTTPS_PROXY -ne $null -join ';')
}

# --- existing runner install -------------------------------------------------
$candidates = @(
    "$env:USERPROFILE\actions-runner",
    "C:\actions-runner",
    "C:\runner",
    "D:\actions-runner"
)
$out.existing_runners = @()
foreach ($c in $candidates) {
    if (Test-Path $c) { $out.existing_runners += $c }
}
if (Test-Path "$env:USERPROFILE\actions-runner\.runner") {
    try { $out.existing_runner_config = Get-Content "$env:USERPROFILE\actions-runner\.runner" -Raw } catch { }
}

# --- llvm-mingw present? -----------------------------------------------------
$out.llvm_mingw = @()
foreach ($p in @('D:\llvm-mingw-xp-22.1.7-msvcrt-x86_64','D:\llvm-mingw-20261104-msvcrt-x86_64','C:\llvm-mingw')) {
    if (Test-Path $p) { $out.llvm_mingw += $p }
}

# --- write result ------------------------------------------------------------
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$jsonPath = Join-Path $here 'probe-result.json'
$json = $out | ConvertTo-Json -Depth 6
Set-Content -LiteralPath $jsonPath -Value $json -Encoding UTF8
Write-Output "PROBE_OK $jsonPath"
Write-Output "--- summary ---"
Write-Output ("os        : {0} ({1})" -f $out.os_caption, $out.os_version)
Write-Output ("arch/ram  : {0} / {1} GB / {2} cores" -f $out.os_arch, $out.ram_gb, $out.cpu_cores)
Write-Output ("admin     : {0}" -f $out.is_admin)
Write-Output ("wsl       : {0}" -f (($out.wsl_distros -join ', ')))
Write-Output ("hypervisor: {0} / hyperv={1} vmplatform={2}" -f $out.virtualization_firmware_enabled, $out.hyperv_feature_state, $out.vm_platform_state)
Write-Output ("net github: {0}" -f $out.net.github_com)
Write-Output ("git/py/cm : {0} / {1} / {2}" -f [bool]$out.tools.git, [bool]$out.tools.python, [bool]$out.tools.cmake)
