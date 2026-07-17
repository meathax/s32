@echo off
REM ===========================================================================
REM  Build SegaS32.rbf on Windows.  Run from anywhere:
REM      tools\build.bat        (from the repo root)
REM      .\build.bat            (from inside tools\)
REM  Set QUARTUS_ROOT if your install is not at D:\Q.
REM ===========================================================================

REM Always operate from the repo root (the parent of this script's folder).
cd /d "%~dp0.."
echo Working directory: %CD%

if "%QUARTUS_ROOT%"=="" set QUARTUS_ROOT=D:\Q

set QBIN=%QUARTUS_ROOT%\quartus\bin64
set QSYS=%QUARTUS_ROOT%\quartus\sopc_builder\bin

if not exist "%QBIN%\quartus_sh.exe" (
  echo ERROR: quartus_sh not found at %QBIN%.
  echo Set QUARTUS_ROOT to your Quartus folder, e.g.  set QUARTUS_ROOT=D:\Q
  exit /b 1
)

echo [1/3] Generating PLL IP (96.648 / 48.324 MHz)...
"%QSYS%\qsys-script.exe" --script=tools/make_pll.tcl
if errorlevel 1 goto :err
"%QSYS%\qsys-generate.exe" rtl/pll/pll.qsys --synthesis=VERILOG --output-directory=rtl/pll
if errorlevel 1 goto :err
if not exist "rtl\pll\synthesis\pll.qip" (
  echo ERROR: Qsys did not generate rtl\pll\synthesis\pll.qip.
  goto :err
)

echo [2/3] Compiling core (this takes 20-60 min)...
"%QBIN%\quartus_sh.exe" --flow compile Arcade-SegaSystem32
if errorlevel 1 goto :err

echo [3/3] Staging RBF...
if not exist releases mkdir releases
copy /Y output_files\Arcade-SegaSystem32.rbf releases\SegaS32.rbf
if errorlevel 1 goto :err

echo.
echo DONE: releases\SegaS32.rbf
echo Copy it to \media\fat\_Arcade\cores\ on the MiSTer SD, and the *.mra
echo files from mra\ to \media\fat\_Arcade\.
exit /b 0

:err
echo.
echo BUILD FAILED - see the message above / output_files\*.rpt for details.
exit /b 1
