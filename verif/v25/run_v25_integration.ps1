[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$wslRoot = (& wsl wslpath -a ($repoRoot -replace '\\', '/')).Trim()
if (-not $wslRoot) {
    throw 'Could not translate the repository path for WSL.'
}

& wsl bash "$wslRoot/verif/v25/run_v25_integration.sh"
if ($LASTEXITCODE -ne 0) {
    throw "V25 integration test failed with exit code $LASTEXITCODE."
}
