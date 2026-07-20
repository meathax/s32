[CmdletBinding()]
param(
    [string]$MisterHost = $env:S32_MISTER_HOST,
    [string]$RbfPath,
    [string]$MraPath,
    [string]$ReportRoot,
    [switch]$SkipMra
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $MisterHost) {
    throw "Pass -MisterHost root@<MISTER-IP> or set S32_MISTER_HOST."
}

if (-not $RbfPath) {
    $RbfPath = Join-Path $repoRoot "releases\SegaS32.rbf"
}
if (-not $ReportRoot) {
    $ReportRoot = $repoRoot
}
if (-not $MraPath) {
    $MraPath = Join-Path $repoRoot "mra\Holosseum (US, Rev A).mra"
}

foreach ($command in @("ssh", "scp")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command was not found. Install the Windows OpenSSH client first."
    }
}

$reportScript = Join-Path $repoRoot "tools\report-quartus.ps1"
Write-Host "Checking fitter, timing, and RBF release gates..."
& $reportScript -ProjectRoot $ReportRoot -RequireReady
# report-quartus.ps1 is a PowerShell script rather than a native process, so
# $LASTEXITCODE may still contain an unrelated earlier program's result.
# PowerShell's invocation status is the authoritative result here.
if (-not $?) {
    throw "Quartus reports do not qualify this build for deployment."
}

$resolvedRbf = (Resolve-Path -LiteralPath $RbfPath).Path
$localRbfHash = (Get-FileHash -LiteralPath $resolvedRbf -Algorithm SHA256).Hash.ToLowerInvariant()
$qualifiedRbf = Join-Path $ReportRoot "output_files\Arcade-SegaSystem32.rbf"
$qualifiedRbfHash = (Get-FileHash -LiteralPath $qualifiedRbf -Algorithm SHA256).Hash.ToLowerInvariant()
if ($localRbfHash -ne $qualifiedRbfHash) {
    throw "Selected RBF does not match the RBF qualified by the Quartus reports."
}

$sshOptions = @("-o", "ConnectTimeout=10")
$remoteCoreDir = "/media/fat/_Arcade/cores"
$remoteRbfTemp = "$remoteCoreDir/.SegaS32.rbf.upload"
$remoteRbfFinal = "$remoteCoreDir/SegaS32.rbf"

Write-Host "Checking MiSTer connection..."
& ssh @sshOptions $MisterHost "mkdir -p '$remoteCoreDir'"
if ($LASTEXITCODE -ne 0) {
    throw "Could not connect to $MisterHost or create $remoteCoreDir."
}

if (-not $SkipMra) {
    $resolvedMra = (Resolve-Path -LiteralPath $MraPath).Path
    $localMraHash = (Get-FileHash -LiteralPath $resolvedMra -Algorithm SHA256).Hash.ToLowerInvariant()
    $mraLeaf = [IO.Path]::GetFileName($resolvedMra)
    if ($mraLeaf.Contains("'")) {
        throw "MRA filenames containing an apostrophe are not supported by the safe SSH quoting path."
    }
    $remoteMraTemp = "/media/fat/_Arcade/.SegaS32.mra.upload"
    $remoteMraFinal = "/media/fat/_Arcade/$mraLeaf"

    Write-Host "Uploading and verifying $mraLeaf..."
    & scp @sshOptions $resolvedMra "${MisterHost}:${remoteMraTemp}"
    if ($LASTEXITCODE -ne 0) {
        throw "MRA upload failed."
    }
    $remoteMraHashLine = & ssh @sshOptions $MisterHost "sha256sum '$remoteMraTemp'"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not hash the uploaded MRA."
    }
    $remoteMraHash = ($remoteMraHashLine -split "\s+")[0].ToLowerInvariant()
    if ($remoteMraHash -ne $localMraHash) {
        throw "MRA hash mismatch: local $localMraHash, remote $remoteMraHash."
    }
    & ssh @sshOptions $MisterHost "mv -f '$remoteMraTemp' '$remoteMraFinal'"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not activate the verified MRA."
    }
}

Write-Host "Uploading and verifying SegaS32.rbf..."
& scp @sshOptions $resolvedRbf "${MisterHost}:${remoteRbfTemp}"
if ($LASTEXITCODE -ne 0) {
    throw "RBF upload failed."
}
$remoteRbfHashLine = & ssh @sshOptions $MisterHost "sha256sum '$remoteRbfTemp'"
if ($LASTEXITCODE -ne 0) {
    throw "Could not hash the uploaded RBF."
}
$remoteRbfHash = ($remoteRbfHashLine -split "\s+")[0].ToLowerInvariant()
if ($remoteRbfHash -ne $localRbfHash) {
    throw "RBF hash mismatch: local $localRbfHash, remote $remoteRbfHash."
}

& ssh @sshOptions $MisterHost "mv -f '$remoteRbfTemp' '$remoteRbfFinal' && sync"
if ($LASTEXITCODE -ne 0) {
    throw "Could not activate the verified RBF."
}

Write-Host "DEPLOYED: $remoteRbfFinal"
Write-Host "SHA256:  $localRbfHash"
Write-Host "ROM files were not copied or modified."
