<#
.SYNOPSIS
    Builds the SharpIpp UWP sample with .NET Native and monitors peak memory of nutc_driver.exe.

.PARAMETER Platform
    Target platform: x64 or ARM64. Default is x64.

.PARAMETER Configuration
    Target configuration. Default is Release.
#>
param(
    [ValidateSet("x64", "ARM64")]
    [string]$Platform = "x64",

    [ValidateSet("Release")]
    [string]$Configuration = "Release",

    [switch]$Rebuild = $true,

    [switch]$Clean
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  SharpIpp .NET Native (nutc_driver.exe) Memory Profiler  " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Platform:      $Platform"
Write-Host "Configuration: $Configuration"
Write-Host "Rebuild:       $Rebuild"
Write-Host ""

if ($Clean) {
    Write-Host "Cleaning bin and obj folders..." -ForegroundColor Yellow
    $binDir = Join-Path $PSScriptRoot "bin"
    $objDir = Join-Path $PSScriptRoot "obj"
    if (Test-Path $binDir) { Remove-Item -Recurse -Force $binDir }
    if (Test-Path $objDir) { Remove-Item -Recurse -Force $objDir }
    Write-Host "Clean complete." -ForegroundColor Green
}

# 1. Locate MSBuild
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found at $vswhere. Visual Studio must be installed."
}

$msbuildPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe | Select-Object -First 1
if (-not $msbuildPath -or -not (Test-Path $msbuildPath)) {
    throw "MSBuild.exe not found."
}
Write-Host "Found MSBuild: $msbuildPath" -ForegroundColor Green

$projectPath = Join-Path $PSScriptRoot "..\SharpIpp.Samples.Client.Uwp\SharpIpp.Samples.Client.Uwp.csproj"
if (-not (Test-Path $projectPath)) {
    throw "Project not found at $projectPath"
}

# 2. Restore NuGet dependencies
Write-Host "`n[1/3] Restoring packages..." -ForegroundColor Yellow
& $msbuildPath $projectPath -t:Restore /p:Platform=$Platform /p:Configuration=$Configuration /v:m
if ($LASTEXITCODE -ne 0) {
    throw "Package restore failed with exit code $LASTEXITCODE."
}
Write-Host "Restore complete." -ForegroundColor Green

# 3. Launch MSBuild in the background and monitor nutc_driver.exe
Write-Host "`n[2/3] Starting build with .NET Native toolchain..." -ForegroundColor Yellow
$logFile = Join-Path $PSScriptRoot "build-$Platform-$Configuration.log"
Write-Host "Build log:     $logFile" -ForegroundColor DarkGray
Write-Host "Live log tip:  Get-Content `"$logFile`" -Wait -Tail 20" -ForegroundColor DarkGray

$targetArg = if ($Rebuild) { "/t:Rebuild" } else { "/t:Build" }
$msbuildArgs = @(
    "`"$projectPath`"",
    $targetArg,
    "/p:Configuration=$Configuration",
    "/p:Platform=$Platform",
    "/p:UseDotNetNativeToolchain=true",
    "/p:Use64BitCompiler=true",
    "/v:normal",
    "/fl",
    "/flp:logfile=`"$logFile`";verbosity=detailed"
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $msbuildPath
$psi.Arguments = $msbuildArgs -join " "
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$buildProcess = [System.Diagnostics.Process]::Start($psi)

# Asynchronously read standard output and standard error to prevent OS pipe deadlocks
$stdoutTask = $buildProcess.StandardOutput.ReadToEndAsync()
$stderrTask = $buildProcess.StandardError.ReadToEndAsync()

Write-Host "`n[3/3] Monitoring nutc_driver.exe memory usage..." -ForegroundColor Yellow
$peakWorkingSet = 0
$peakPagedMemory = 0
$nutcObserved = $false
$startTime = Get-Date
$lastHeartbeat = [DateTime]::MinValue

try {
    while (-not $buildProcess.HasExited) {
        $now = Get-Date
        $elapsed = $now - $startTime
        $elapsedStr = [string]::Format("{0:mm\:ss}", $elapsed)

        $nutcProcesses = Get-Process -Name "nutc_driver" -ErrorAction SilentlyContinue
        if ($nutcProcesses) {
            $nutcObserved = $true
            $currentWs = ($nutcProcesses | Measure-Object -Property WorkingSet64 -Sum).Sum
            $currentPm = ($nutcProcesses | Measure-Object -Property PagedMemorySize64 -Sum).Sum

            if ($currentWs -gt $peakWorkingSet) {
                $peakWorkingSet = $currentWs
                $currentGb = [Math]::Round($currentWs / 1GB, 2)
                $currentMb = [Math]::Round($currentWs / 1MB, 0)
                Write-Host "  --> [$elapsedStr] nutc_driver.exe peak WorkingSet updated: $currentGb GB ($currentMb MB)" -ForegroundColor Magenta
            }
            if ($currentPm -gt $peakPagedMemory) {
                $peakPagedMemory = $currentPm
            }
        }

        # Print heartbeat every 5 seconds to provide visibility into current build phase
        if ($now - $lastHeartbeat -ge [TimeSpan]::FromSeconds(5)) {
            $lastHeartbeat = $now
            if ($nutcProcesses) {
                $currentGb = [Math]::Round(($nutcProcesses | Measure-Object -Property WorkingSet64 -Sum).Sum / 1GB, 2)
                $peakGb = [Math]::Round($peakWorkingSet / 1GB, 2)
                Write-Host "  [$elapsedStr] nutc_driver active | Current WS: $currentGb GB | Peak: $peakGb GB" -ForegroundColor Cyan
            } elseif ($nutcObserved) {
                Write-Host "  [$elapsedStr] nutc_driver native compilation completed. MSBuild finalizing..." -ForegroundColor DarkCyan
            } else {
                $activeCompiler = (Get-Process -Name "ilc", "Csc", "link", "mspdbcmf" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique) -join ", "
                if (-not $activeCompiler) { $activeCompiler = "MSBuild core tasks" }
                Write-Host "  [$elapsedStr] Pre-native phase... Active tools: $activeCompiler" -ForegroundColor DarkGray
            }
        }

        Start-Sleep -Milliseconds 250
    }

    $buildProcess.WaitForExit()
} finally {
    if (-not $buildProcess.HasExited) {
        Write-Host "`nCancelling build process..." -ForegroundColor Yellow
        try {
            $buildProcess.Kill()
        } catch {}
    }
}

$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
$exitCode = $buildProcess.ExitCode
$duration = (Get-Date) - $startTime

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "                   BUILD & PROFILING RESULTS               " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Total Duration:        $([Math]::Round($duration.TotalSeconds, 1)) seconds"
Write-Host "Build Result:          $(if ($exitCode -eq 0) { 'SUCCESS' } else { 'FAILED (exit code ' + $exitCode + ')' })" -ForegroundColor $(if ($exitCode -eq 0) { 'Green' } else { 'Red' })
Write-Host "nutc_driver Observed:  $nutcObserved"

if ($nutcObserved) {
    $peakWsGb = [Math]::Round($peakWorkingSet / 1GB, 2)
    $peakPmGb = [Math]::Round($peakPagedMemory / 1GB, 2)
    Write-Host "Peak WorkingSet:       $peakWsGb GB ($([Math]::Round($peakWorkingSet / 1MB, 0)) MB)" -ForegroundColor Yellow
    Write-Host "Peak Paged Memory:     $peakPmGb GB ($([Math]::Round($peakPagedMemory / 1MB, 0)) MB)" -ForegroundColor Yellow
} else {
    Write-Host "Note: nutc_driver.exe was not detected during this build." -ForegroundColor DarkYellow
    Write-Host "Check build log: $logFile"
}

if ($exitCode -ne 0) {
    Write-Host "`nBuild Output Summary:" -ForegroundColor Red
    $allOutput = "$stdout`n$stderr"
    $errorLines = $allOutput.Split("`n") | Where-Object { $_ -match "error\s+([A-Z0-9]+)?:" -or $_ -match ":\s*error\b" }
    if ($errorLines) {
        $errorLines | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    } else {
        Write-Host "See detailed log: $logFile" -ForegroundColor Yellow
    }
}
