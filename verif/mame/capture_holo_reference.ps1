#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateRange(5, 600)]
    [int]$Seconds = 22,
    [string]$Distribution = "Ubuntu",
    [string]$OutputDirectory = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $root "roms\reference\holo"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Convert-ToWslPath([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $drive = $resolved.Substring(0, 1).ToLowerInvariant()
    return "/mnt/$drive/" + $resolved.Substring(3).Replace("\", "/")
}

$wslRoot = Convert-ToWslPath $root
$wslOutput = Convert-ToWslPath $OutputDirectory
$romPath = "$wslRoot/roms"
$scriptPath = "$wslRoot/verif/mame/holo_reference.lua"
$tracePath = "$wslOutput/trace.csv"

$command = @"
set -euo pipefail
mkdir -p '$wslOutput'
mame -version > '$wslOutput/mame-version.txt'
mame -rompath '$romPath' -verifyroms holo > '$wslOutput/verifyroms.txt'
mame -rompath '$romPath' -listxml holo > '$wslOutput/holo.xml'
export S32_MAME_TRACE='$tracePath'
mame holo -rompath '$romPath' -skip_gameinfo -nothrottle -video none \
  -seconds_to_run $Seconds -autoboot_script '$scriptPath' \
  -snapshot_directory '$wslOutput' -snapname 'holo-%i' -snapview native \
  -aviwrite '$wslOutput/holo.avi' -wavwrite '$wslOutput/holo.wav'
"@

& wsl.exe -d $Distribution -- bash -lc $command
if ($LASTEXITCODE -ne 0) {
    throw "MAME Holosseum reference capture failed with exit code $LASTEXITCODE."
}

$required = @("mame-version.txt", "verifyroms.txt", "holo.xml", "trace.csv")
foreach ($name in $required) {
    $path = Join-Path $OutputDirectory $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "MAME capture did not produce $path"
    }
}

$hashes = Get-ChildItem -LiteralPath $OutputDirectory -File |
    Sort-Object Name |
    Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "{0}  {1}" -f $_.Hash.ToLowerInvariant(), (Split-Path -Leaf $_.Path) }
Set-Content -LiteralPath (Join-Path $OutputDirectory "SHA256SUMS") -Value $hashes

Write-Host "HOLO MAME REFERENCE PASS"
Write-Host "Output: $OutputDirectory"
