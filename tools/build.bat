@echo off
REM ===========================================================================
REM  Build SegaS32.rbf on Windows.  Run from anywhere:
REM      tools\build.bat        (from the repo root)
REM      .\build.bat            (from inside tools\)
REM  Set QUARTUS_ROOT to the directory containing quartus\bin64.
REM ===========================================================================

REM Always operate from the repo root (the parent of this script's folder).
cd /d "%~dp0.."
echo Working directory: %CD%

if "%QUARTUS_ROOT%"=="" (
  echo ERROR: QUARTUS_ROOT is not set.
  echo Set it to your Quartus installation, e.g.  set QUARTUS_ROOT=C:\intelFPGA_lite\17.0
  exit /b 1
)

set QBIN=%QUARTUS_ROOT%\quartus\bin64
set QSYS=%QUARTUS_ROOT%\quartus\sopc_builder\bin

if not exist "%QBIN%\quartus_sh.exe" (
  echo ERROR: quartus_sh not found at %QBIN%.
  echo Set QUARTUS_ROOT to your Quartus folder, e.g.  set QUARTUS_ROOT=C:\intelFPGA_lite\17.0
  exit /b 1
)

echo [1/7] Removing stale Quartus databases and output...
if exist "%CD%\db" rmdir /S /Q "%CD%\db"
if exist "%CD%\incremental_db" rmdir /S /Q "%CD%\incremental_db"
if exist "%CD%\output_files" rmdir /S /Q "%CD%\output_files"

echo [2/7] Generating PLL IP (96.648 / 48.324 MHz)...
"%QSYS%\qsys-script.exe" --script=tools/make_pll.tcl
if errorlevel 1 goto :err
"%QSYS%\qsys-generate.exe" rtl/pll/pll.qsys --synthesis=VERILOG --output-directory=rtl/pll
if errorlevel 1 goto :err
if not exist "rtl\pll\synthesis\pll.qip" (
  echo ERROR: Qsys did not generate rtl\pll\synthesis\pll.qip.
  goto :err
)

echo [3/7] Running Analysis and Synthesis...
"%QBIN%\quartus_map.exe" --read_settings_files=on --write_settings_files=off Arcade-SegaSystem32 -c Arcade-SegaSystem32
if errorlevel 1 goto :err

if not defined S32_FIT_SEEDS set S32_FIT_SEEDS=6 1 2 3 4 5
if not defined S32_FIT_RETRIES set S32_FIT_RETRIES=3
echo [4/7] Fitting core with crash retries and timing seed sweep...
for %%S in (%S32_FIT_SEEDS%) do (
  call :try_seed %%S
  if not errorlevel 1 goto :done
)
echo No fitter seed produced a timing-qualified result.
goto :err

:done
echo.
echo DONE: releases\SegaS32.rbf
echo Copy it to \media\fat\_Arcade\cores\ on the MiSTer SD, and the *.mra
echo files from mra\ to \media\fat\_Arcade\.
exit /b 0

:try_seed
set FIT_SEED=%1
set FIT_ATTEMPT=0
:fit_retry
set /A FIT_ATTEMPT+=1
echo Fitter seed %FIT_SEED%, attempt %FIT_ATTEMPT% of %S32_FIT_RETRIES%...
"%QBIN%\quartus_fit.exe" --read_settings_files=off --write_settings_files=off --seed=%FIT_SEED% Arcade-SegaSystem32 -c Arcade-SegaSystem32
if not errorlevel 1 goto :fit_ok
if %FIT_ATTEMPT% GEQ %S32_FIT_RETRIES% exit /b 1
echo Fitter ended unexpectedly; retrying from the synthesized netlist...
goto :fit_retry

:fit_ok
echo [5/7] Assembling candidate RBF...
"%QBIN%\quartus_asm.exe" --read_settings_files=off --write_settings_files=off Arcade-SegaSystem32 -c Arcade-SegaSystem32
if errorlevel 1 exit /b 1

echo [6/7] Running multicorner timing analysis...
"%QBIN%\quartus_sta.exe" Arcade-SegaSystem32 -c Arcade-SegaSystem32
if errorlevel 1 exit /b 1

echo [7/7] Verifying fit, timing, and RBF freshness...
powershell -NoProfile -ExecutionPolicy Bypass -File tools\report-quartus.ps1 -RequireReady
if errorlevel 1 (
  echo Seed %FIT_SEED% did not qualify; trying the next seed.
  exit /b 1
)

if not exist releases mkdir releases
copy /Y output_files\Arcade-SegaSystem32.rbf releases\SegaS32.rbf
if errorlevel 1 exit /b 1
echo Qualified fitter seed %FIT_SEED%.
exit /b 0

:err
echo.
echo BUILD FAILED - see the message above / output_files\*.rpt for details.
exit /b 1
