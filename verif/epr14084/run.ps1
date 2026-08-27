$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'tb_bus.out'
iverilog -g2012 -o $out (Join-Path $PSScriptRoot 'tb_bus.sv') (Join-Path $PSScriptRoot '../../rtl/comm/epr14084/epr14084_bus.sv')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
vvp $out
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
python -B -m unittest discover -s $PSScriptRoot -p 'test_*.py'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$work = Join-Path $PSScriptRoot 'ghdl_work'
New-Item -ItemType Directory -Force $work | Out-Null
$t80 = Join-Path $PSScriptRoot '../../rtl/audio/T80'
ghdl -a --std=08 -fsynopsys --workdir=$work (Join-Path $t80 'T80_ALU.vhd') (Join-Path $t80 'T80_MCode.vhd') (Join-Path $t80 'T80_Reg.vhd') (Join-Path $t80 'T80.vhd') (Join-Path $t80 'T80s.vhd') (Join-Path $PSScriptRoot 'tb_t80_im0.vhd')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
ghdl -e --std=08 -fsynopsys --workdir=$work tb_t80_im0
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
ghdl -r --std=08 -fsynopsys --workdir=$work tb_t80_im0 --assert-level=error
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($env:EPR14084_HEX) {
	ghdl -a --std=08 -fsynopsys --workdir=$work (Join-Path $PSScriptRoot 'tb_t80_firmware.vhd')
	if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
	ghdl -e --std=08 -fsynopsys --workdir=$work tb_t80_firmware
	if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
	ghdl -r --std=08 -fsynopsys --workdir=$work tb_t80_firmware "-gROM_HEX=$($env:EPR14084_HEX)" --assert-level=error
	if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
Remove-Item -LiteralPath $work -Recurse -Force
Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
