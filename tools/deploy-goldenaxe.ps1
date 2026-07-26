[CmdletBinding()]
param(
    [string]$MisterHost = $env:S32_MISTER_HOST,
    [string]$MraPath,
    [switch]$SkipMra
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $MraPath) {
    $MraPath = Join-Path $repoRoot "mra\Golden Axe The Revenge of Death Adder (World, Rev B).mra"
}

& (Join-Path $PSScriptRoot "deploy-mister.ps1") `
    -MisterHost $MisterHost `
    -Revision "s32GoldenAxe" `
    -CoreName "s32GoldenAxe" `
    -MraPath $MraPath `
    -SkipMra:$SkipMra
