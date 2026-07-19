[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Revision = "Arcade-SegaSystem32",
    [switch]$AsJson,
    [switch]$RequireReady
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$outputDir = Join-Path $ProjectRoot "output_files"

function Read-OptionalFile([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return Get-Content -LiteralPath $Path -Raw
    }
    return $null
}

function Match-Value([string]$Text, [string]$Pattern) {
    if (-not $Text) {
        return $null
    }
    $match = [regex]::Match($Text, $Pattern)
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    return $null
}

$mapSummaryPath = Join-Path $outputDir "$Revision.map.summary"
$fitSummaryPath = Join-Path $outputDir "$Revision.fit.summary"
$staSummaryPath = Join-Path $outputDir "$Revision.sta.summary"
$mapReportPath = Join-Path $outputDir "$Revision.map.rpt"
$fitReportPath = Join-Path $outputDir "$Revision.fit.rpt"
$rbfPath = Join-Path $outputDir "$Revision.rbf"
$qsfPath = Join-Path $ProjectRoot "$Revision.qsf"

$mapSummary = Read-OptionalFile $mapSummaryPath
$fitSummary = Read-OptionalFile $fitSummaryPath
$staSummary = Read-OptionalFile $staSummaryPath
$mapReport = Read-OptionalFile $mapReportPath
$fitReport = Read-OptionalFile $fitReportPath
$qsf = Read-OptionalFile $qsfPath

$mapStatus = Match-Value $mapSummary '(?m)^Analysis & Synthesis Status\s*:\s*(.+)$'
$fitStatus = Match-Value $fitSummary '(?m)^Fitter Status\s*:\s*(.+)$'
$mapSuccessful = $mapStatus -like 'Successful*'
$fitSuccessful = $fitStatus -like 'Successful*'
$fitFinished = [bool]$fitStatus

# A successful status can still belong to an older netlist.  Require the
# chronological build chain to follow the newest synthesis input so an old
# fit/RBF can never qualify after RTL or project settings change.
$buildExtensions = @(
    '.qpf', '.qsf', '.qip', '.qsys', '.sdc', '.tcl',
    '.sv', '.svh', '.v', '.vh', '.vhd', '.vhdl',
    '.mif', '.hex', '.mem'
)
$buildInputs = @(
    Get-ChildItem -LiteralPath $ProjectRoot -File -ErrorAction SilentlyContinue
    foreach ($tree in @('rtl', 'sys')) {
        $treePath = Join-Path $ProjectRoot $tree
        if (Test-Path -LiteralPath $treePath -PathType Container) {
            Get-ChildItem -LiteralPath $treePath -Recurse -File -ErrorAction SilentlyContinue
        }
    }
) | Where-Object { $buildExtensions -contains $_.Extension.ToLowerInvariant() }
$newestBuildInput = $buildInputs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$mapSummaryFile = Get-Item -LiteralPath $mapSummaryPath -ErrorAction SilentlyContinue
$fitSummaryFile = Get-Item -LiteralPath $fitSummaryPath -ErrorAction SilentlyContinue
$staSummaryFile = Get-Item -LiteralPath $staSummaryPath -ErrorAction SilentlyContinue
$mapIsCurrent = $mapSuccessful -and [bool]$mapSummaryFile -and
    (-not $newestBuildInput -or $mapSummaryFile.LastWriteTimeUtc -ge $newestBuildInput.LastWriteTimeUtc)
$fitIsCurrent = $fitSuccessful -and $mapIsCurrent -and [bool]$fitSummaryFile -and
    $fitSummaryFile.LastWriteTimeUtc -ge $mapSummaryFile.LastWriteTimeUtc
$staIsCurrent = $fitIsCurrent -and [bool]$staSummaryFile -and
    $staSummaryFile.LastWriteTimeUtc -ge $fitSummaryFile.LastWriteTimeUtc

$timingRows = @()
if ($staIsCurrent -and $staSummary) {
    $timingMatches = [regex]::Matches(
        $staSummary,
        "(?ms)^Type\s+:\s+(.+?)\r?\nSlack\s+:\s+(-?\d+(?:\.\d+)?)"
    )
    foreach ($match in $timingMatches) {
        $timingRows += [pscustomobject]@{
            Type = $match.Groups[1].Value.Trim()
            Slack = [double]::Parse(
                $match.Groups[2].Value,
                [Globalization.CultureInfo]::InvariantCulture
            )
        }
    }
}

$worstTiming = $timingRows | Sort-Object Slack | Select-Object -First 1
$timingMet = $staIsCurrent -and $timingRows.Count -gt 0 -and $worstTiming.Slack -ge 0

$rbf = Get-Item -LiteralPath $rbfPath -ErrorAction SilentlyContinue
$rbfIsCurrent = $fitIsCurrent -and [bool]$rbf -and [bool]$fitSummaryFile -and
    $rbf.LastWriteTimeUtc -ge $fitSummaryFile.LastWriteTimeUtc

$routeAverage = Match-Value $fitReport 'Router estimated average interconnect usage is (\d+%)'
$routePeak = Match-Value $fitReport 'Router estimated peak interconnect usage is (\d+%)'
$routeRegionMatch = if ($fitReport) {
    [regex]::Match(
        $fitReport,
        'region that extends from location (\S+) to location (\S+)'
    )
}
$routeRegion = if ($routeRegionMatch.Success) {
    "$($routeRegionMatch.Groups[1].Value) to $($routeRegionMatch.Groups[2].Value)"
}
$congestionFailure = $fitReport -match 'routing phase terminated due to routing congestion'

$ready = $mapIsCurrent -and $fitIsCurrent -and $staIsCurrent -and $timingMet -and $rbfIsCurrent
$result = [ordered]@{
    ProjectRoot = $ProjectRoot
    Revision = $Revision
    Seed = Match-Value $qsf '(?m)^set_global_assignment -name SEED\s+(\d+)\s*$'
    MapStatus = $mapStatus
    MapCurrent = $mapIsCurrent
    MapEstimatedALMs = Match-Value $mapReport '; Estimate of Logic utilization \(ALMs needed\)\s*;\s*(\d+)'
    MapCombinationalALUTs = Match-Value $mapReport '; Combinational ALUT usage for logic\s*;\s*(\d+)'
    MapDedicatedRegisters = Match-Value $mapReport '; Dedicated logic registers\s*;\s*(\d+)'
    FitStatus = $fitStatus
    FitCurrent = $fitIsCurrent
    LogicALMs = Match-Value $fitSummary '(?m)^Logic utilization \(in ALMs\)\s*:\s*(.+)$'
    Registers = Match-Value $fitSummary '(?m)^Total registers\s*:\s*(.+)$'
    BlockMemoryBits = Match-Value $fitSummary '(?m)^Total block memory bits\s*:\s*(.+)$'
    RAMBlocks = Match-Value $fitSummary '(?m)^Total RAM Blocks\s*:\s*(.+)$'
    DSPBlocks = Match-Value $fitSummary '(?m)^Total DSP Blocks\s*:\s*(.+)$'
    PLLs = Match-Value $fitSummary '(?m)^Total PLLs\s*:\s*(.+)$'
    RouteAverage = $routeAverage
    RoutePeak = $routePeak
    RoutePeakRegion = $routeRegion
    CongestionFailure = $congestionFailure
    WorstTimingType = if ($worstTiming) { $worstTiming.Type } else { $null }
    WorstSlackNs = if ($worstTiming) { $worstTiming.Slack } else { $null }
    TimingMet = $timingMet
    TimingCurrent = $staIsCurrent
    LatestBuildInput = if ($newestBuildInput) { $newestBuildInput.FullName } else { $null }
    RbfPath = if ($rbf) { $rbf.FullName } else { $null }
    RbfCurrent = $rbfIsCurrent
    ReadyToDeploy = $ready
}

if ($AsJson) {
    [pscustomobject]$result | ConvertTo-Json
}
else {
    Write-Host "Quartus result: seed $($result.Seed)"
    Write-Host "  Map:        $(if ($result.MapStatus) { $result.MapStatus } else { 'pending or not run' }); current=$mapIsCurrent"
    if ($result.MapEstimatedALMs) {
        Write-Host "  Map area:   $($result.MapEstimatedALMs) estimated ALMs; $($result.MapCombinationalALUTs) combinational ALUTs"
    }
    Write-Host "  Fit:        $(if ($result.FitStatus) { $result.FitStatus } else { 'pending or not run' }); current=$fitIsCurrent"
    if ($result.LogicALMs) {
        Write-Host "  Resources:  $($result.LogicALMs) ALMs; $($result.RAMBlocks) RAM blocks"
    }
    if ($routeAverage -or $routePeak) {
        Write-Host "  Routing:    average $routeAverage; peak $routePeak; $routeRegion"
    }
    if ($staIsCurrent) {
        Write-Host "  Timing:     worst $($result.WorstSlackNs) ns; met=$timingMet; current=True"
    }
    else {
        Write-Host "  Timing:     pending or stale; current=False"
    }
    Write-Host "  RBF:        $(if ($rbf) { $rbf.FullName } else { 'missing' }); current=$rbfIsCurrent"
    Write-Host "  Deployable: $ready"
}

if ($RequireReady -and -not $ready) {
    exit 1
}
