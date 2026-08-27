Set-StrictMode -Version Latest

function New-S32VerilatorWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$SafeLauncher,
        [string]$ModelDirectoryName = 'obj_dir'
    )

    $workspace = (& $SafeLauncher workspace 2>&1 | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0 -or $workspace -notmatch '^[Rr]:\\Verilator\\') {
        throw "Safe launcher returned an invalid Verilator workspace: $workspace"
    }
    $env:VERILATOR_WORKSPACE = $workspace
    $env:VERILATOR_PROJECT = 's32'
    $modelDirectory = Join-Path $workspace $ModelDirectoryName
    New-Item -ItemType Directory -Path $modelDirectory -Force | Out-Null
    return [IO.Path]::GetFullPath($modelDirectory)
}
