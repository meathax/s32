#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateRange(4, 60)]
    [int]$Seconds = 8,
    [string]$Distribution = "Ubuntu",
    [string]$OutputPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
if (-not $OutputPath) {
    $OutputPath = Join-Path $root "scratch\mame_ga2_select_trace.log"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

function Convert-ToWslPath([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $drive = $resolved.Substring(0, 1).ToLowerInvariant()
    return "/mnt/$drive/" + $resolved.Substring(3).Replace("\", "/")
}

$wslRoot = Convert-ToWslPath $root
$wslOutput = Convert-ToWslPath $OutputPath
$wslOutputDirectory = $wslOutput.Substring(0, $wslOutput.LastIndexOf('/'))
$romPath = "$wslRoot/roms"
$scriptPath = "$wslRoot/verif/mame/ga2_select_trace.lua"

$command = @"
set -euo pipefail
mkdir -p '$wslOutputDirectory'
export GA2_TRACE_OUT='$wslOutput'
mame ga2 -rompath '$romPath' -skip_gameinfo -nothrottle -video none -sound none \
  -seconds_to_run $Seconds -autoboot_script '$scriptPath'
"@

& wsl.exe -d $Distribution -- bash -lc $command
if ($LASTEXITCODE -ne 0) {
    throw "MAME GA2 select trace failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
    throw "MAME capture did not produce $OutputPath"
}
if ((Get-Item -LiteralPath $OutputPath).Length -eq 0) {
    throw "MAME capture produced an empty trace: $OutputPath"
}
if (-not (Select-String -LiteralPath $OutputPath -Pattern '^\[state\] ' -Quiet)) {
    throw "MAME trace ended before the final [state] record: $OutputPath"
}

Write-Host "GA2 MAME SELECT TRACE PASS"
Write-Host "Output: $OutputPath"
