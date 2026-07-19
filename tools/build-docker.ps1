[CmdletBinding()]
param(
    [string]$Image = "raetro/quartus:17.0",
    [switch]$SkipPull
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

Push-Location $repoRoot
try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker CLI was not found. Install and start Docker Desktop first."
    }

    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Desktop is not running. Start it, then rerun this command."
    }

    if (-not $SkipPull) {
        Write-Host "[1/4] Pulling Quartus 17.0.2 container..."
        & docker pull $Image
        if ($LASTEXITCODE -ne 0) {
            throw "Could not pull Docker image $Image."
        }
    }
    else {
        Write-Host "[1/4] Reusing local image $Image..."
    }

    Write-Host "[2/4] Generating PLL and compiling with all available processors..."
    $compile = @'
qsys-script --script=tools/make_pll.tcl &&
qsys-generate rtl/pll/pll.qsys --synthesis=VERILOG --output-directory=rtl/pll &&
test -f rtl/pll/synthesis/pll.qip &&
quartus_sh --flow compile Arcade-SegaSystem32
'@
    $volume = "${repoRoot}:/build"
    & docker run --rm --workdir /build --volume $volume $Image bash -c $compile
    if ($LASTEXITCODE -ne 0) {
        throw "Quartus compilation failed. Inspect output_files/*.rpt for details."
    }

    $builtRbf = Join-Path $repoRoot "output_files\Arcade-SegaSystem32.rbf"
    if (-not (Test-Path -LiteralPath $builtRbf -PathType Leaf)) {
        throw "Quartus exited successfully but did not produce $builtRbf."
    }

    Write-Host "[3/4] Qualifying fitter, timing, and RBF reports..."
    & (Join-Path $PSScriptRoot "report-quartus.ps1") -ProjectRoot $repoRoot -RequireReady
    if ($LASTEXITCODE -ne 0) {
        throw "Quartus completed but the build did not pass the release gates."
    }

    Write-Host "[4/4] Staging RBF..."
    $releaseDir = Join-Path $repoRoot "releases"
    New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
    Copy-Item -LiteralPath $builtRbf -Destination (Join-Path $releaseDir "SegaS32.rbf") -Force

    Write-Host "DONE: releases\SegaS32.rbf"
}
finally {
    Pop-Location
}
