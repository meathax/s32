[CmdletBinding()]
param(
    [string]$ModelSimBin = ""
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$msysRoot = 'D:\vibes\fpga\toolchains\msys64'
$msysBash = Join-Path $msysRoot 'usr\bin\bash.exe'
if (Test-Path -LiteralPath $msysBash -PathType Leaf) {
    $script = ($repoRoot -replace '\\', '/') + '/verif/v25/run_v25_firmware.sh'
    $buildDir = $null
    $validatedBuildDir = $false
    $savedPath = $env:PATH
    $savedSafe = $env:S32_VERILATOR_SAFE
    $savedSimSafe = $env:S32_VERILATOR_SIM_SAFE
    $savedModelSim = $env:MODELSIM_BIN
    $savedTmp = $env:TMP
    $savedTemp = $env:TEMP
    $savedBuildOnly = $env:S32_V25_BUILD_ONLY
    $savedKeepBuild = $env:KEEP_BUILD
    try {
        $env:PATH = (Join-Path $msysRoot 'ucrt64\bin') + ';' + (Join-Path $msysRoot 'usr\bin') + ';D:\vibes\fpga\bin;' + $savedPath
        $safeVerilator = (Get-Command verilator-safe -ErrorAction Stop).Source
        $safeSimulator = (Get-Command verilator-sim-safe -ErrorAction Stop).Source
        $env:S32_VERILATOR_SAFE = ($safeVerilator -replace '\\', '/')
        $env:S32_VERILATOR_SIM_SAFE = ($safeSimulator -replace '\\', '/')
        $modelSimDirectory = $ModelSimBin
        if (-not $modelSimDirectory) {
            $modelSimDirectory = $savedModelSim
        }
        if (-not $modelSimDirectory) {
            $modelSimDirectory = Split-Path -Parent (
                Get-Command vsim.exe -ErrorAction Stop).Source
        }
        $modelSimDirectory = [IO.Path]::GetFullPath($modelSimDirectory)
        foreach ($tool in ("vlib.exe", "vlog.exe", "vsim.exe")) {
            if (-not (Test-Path -LiteralPath (Join-Path $modelSimDirectory $tool) -PathType Leaf)) {
                throw "ModelSim directory is missing $tool`: $modelSimDirectory"
            }
        }
        $env:MODELSIM_BIN = ($modelSimDirectory -replace '\\', '/')
        $env:S32_V25_BUILD_ONLY = '1'
        $env:KEEP_BUILD = '1'

        [string[]]$buildOutput = & $msysBash -lc $script 2>&1
        $buildExitCode = $LASTEXITCODE
        $buildOutput | ForEach-Object { Write-Output $_ }
        if ($buildExitCode -ne 0) {
            throw "V25 firmware build failed with exit code $buildExitCode."
        }

        $exePrefix = 'V25_FIRMWARE EXE: '
        $dirPrefix = 'V25_FIRMWARE BUILD DIR: '
        $exeLine = $buildOutput | Where-Object { $_.StartsWith($exePrefix) } | Select-Object -Last 1
        $dirLine = $buildOutput | Where-Object { $_.StartsWith($dirPrefix) } | Select-Object -Last 1
        if (-not $exeLine -or -not $dirLine) {
            throw 'V25 firmware build did not report its executable and build directory.'
        }

        $firmwareExe = $exeLine.Substring($exePrefix.Length).Trim()
        $buildDir = $dirLine.Substring($dirPrefix.Length).Trim()
        $buildDir = [IO.Path]::GetFullPath($buildDir).TrimEnd('\')
        $firmwareExe = [IO.Path]::GetFullPath($firmwareExe)
        $expectedPrefix = 'R:\Verilator\'
        $expectedExe = Join-Path $buildDir 'obj_dir\Vtb_v25_firmware.exe'
        if (-not $buildDir.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $buildDir).StartsWith('s32-v25-firmware.', [StringComparison]::Ordinal) -or
            -not $firmwareExe.Equals($expectedExe, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing an unexpected V25 firmware build path: $buildDir"
        }
        $validatedBuildDir = $true
        if (-not (Test-Path -LiteralPath $firmwareExe -PathType Leaf)) {
            throw "V25 firmware executable was not produced: $firmwareExe"
        }

        [string[]]$runOutput = & $safeSimulator -- $firmwareExe 2>&1
        $runExitCode = $LASTEXITCODE
        $runOutput | ForEach-Object { Write-Output $_ }
        if ($runExitCode -ne 0) {
            throw "V25 firmware simulation failed with exit code $runExitCode."
        }
        $passMarker = 'V25_FIRMWARE PASS: genuine GA2 firmware wrote wake-up, table, and stack state'
        if (-not ($runOutput | Where-Object { $_.Contains($passMarker) })) {
            throw 'V25 firmware simulation completion marker is missing.'
        }

        Write-Output 'V25_ROM_CACHE RUNNER: PASS'
        Write-Output 'V25_INTERNAL_DATA RUNNER: PASS'
        Write-Output 'V25_FIRMWARE WAKE: PASS'
        Write-Output 'V25_FIRMWARE TABLE: PASS'
        Write-Output 'V25_FIRMWARE RUNNER: PASS'
    }
    finally {
        $env:PATH = $savedPath
        $env:S32_VERILATOR_SAFE = $savedSafe
        $env:S32_VERILATOR_SIM_SAFE = $savedSimSafe
        $env:MODELSIM_BIN = $savedModelSim
        $env:TMP = $savedTmp
        $env:TEMP = $savedTemp
        $env:S32_V25_BUILD_ONLY = $savedBuildOnly
        $env:KEEP_BUILD = $savedKeepBuild
        if ($validatedBuildDir -and (Test-Path -LiteralPath $buildDir)) {
            Remove-Item -LiteralPath $buildDir -Recurse -Force
        }
        elseif ($buildDir -and (Test-Path -LiteralPath $buildDir)) {
            Write-Warning "Retained unvalidated V25 firmware build directory: $buildDir"
        }
    }
}
else {
    throw 'MSYS2 bash is required for the native Windows V25 firmware runner.'
}
