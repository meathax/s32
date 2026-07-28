[CmdletBinding()]
param(
    [string]$MisterHost = $env:S32_MISTER_HOST,
    [string]$MraPath,
    [switch]$SkipMra
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $MraPath) {
    $MraPath = Join-Path $repoRoot "mra\Arabian Fight (World).mra"
}

& (Join-Path $PSScriptRoot "deploy-mister.ps1") `
    -MisterHost $MisterHost `
    -Revision "s32ArabianFight" `
    -CoreName "s32ArabianFight" `
    -MraPath $MraPath `
    -SkipMra:$SkipMra
