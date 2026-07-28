[CmdletBinding()]
param(
    [string]$MisterHost = $env:S32_MISTER_HOST,
    [string]$MraPath,
    [switch]$SkipMra
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $MraPath) {
    $MraPath = Join-Path $repoRoot "mra\Alien3 The Gun (World).mra"
}

& (Join-Path $PSScriptRoot "deploy-mister.ps1") `
    -MisterHost $MisterHost `
    -Revision "s32Alien3" `
    -CoreName "s32Alien3" `
    -MraPath $MraPath `
    -SkipMra:$SkipMra
