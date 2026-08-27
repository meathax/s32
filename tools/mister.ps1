param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"
$Script = Join-Path $PSScriptRoot "mister.py"

if (Get-Command py -ErrorAction SilentlyContinue) {
    & py -3 $Script @Arguments
    exit $LASTEXITCODE
}
if (Get-Command python -ErrorAction SilentlyContinue) {
    & python $Script @Arguments
    exit $LASTEXITCODE
}
throw "Python 3 was not found. The installer validation should have detected this."
