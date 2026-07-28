@echo off
setlocal EnableExtensions

REM Fit/STA-only timing loop for the dedicated Arabian Fight revision.
REM It deliberately never invokes quartus_asm or creates/stages an RBF.
if /I "%S32_BUILD_LOCK_HELD%"=="1" if defined S32_BUILD_LOCK_TOKEN goto :locked
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0invoke-build-locked.ps1" -BuildScript "%~f0" -WaitSeconds 3600
set "RESULT=%ERRORLEVEL%"
endlocal & exit /b %RESULT%

:locked
cd /d "%~dp0.."
if not "%ERRORLEVEL%"=="0" goto :error
if not defined QUARTUS_ROOT goto :no_quartus
set "QBIN=%QUARTUS_ROOT%\quartus\bin64"

powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync-arabianfight-qsf.ps1
if not "%ERRORLEVEL%"=="0" goto :error

powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-preflight.ps1 ^
  -ProjectRoot "%CD%" -QuartusRoot "%QUARTUS_ROOT%" ^
  -Project "s32ArabianFight" -Revision "s32ArabianFight" ^
  -ReleaseName "s32ArabianFight" -FitSeeds "1" ^
  -MapRetries "1" -FitRetries "1" -ResumeFit "1"
if not "%ERRORLEVEL%"=="0" goto :error

REM Reuse a byte-for-byte current synthesized netlist when an interrupted
REM timing iteration already completed map. Rebuild only when the manifest
REM proves that an HDL/QSF input changed.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\report-quartus.ps1 ^
  -ProjectRoot "%CD%" -Revision "s32ArabianFight" ^
  -QuartusRoot "%QUARTUS_ROOT%" -RequireMapCurrent
if "%ERRORLEVEL%"=="0" goto :map_ready

echo [1/4] Incremental analysis and synthesis...
"%QBIN%\quartus_map.exe" --read_settings_files=on --write_settings_files=off "s32ArabianFight" -c "s32ArabianFight"
if not "%ERRORLEVEL%"=="0" goto :error

powershell -NoProfile -ExecutionPolicy Bypass -File tools\report-quartus.ps1 ^
  -ProjectRoot "%CD%" -Revision "s32ArabianFight" ^
  -QuartusRoot "%QUARTUS_ROOT%" -WriteMapManifest -RequireMapCurrent
if not "%ERRORLEVEL%"=="0" goto :error

:map_ready

echo [2/4] Fast Fit, seed 1...
"%QBIN%\quartus_fit.exe" --read_settings_files=on --write_settings_files=off --seed=1 "s32ArabianFight" -c "s32ArabianFight"
if not "%ERRORLEVEL%"=="0" goto :error

echo [3/4] Multicorner timing analysis...
"%QBIN%\quartus_sta.exe" "s32ArabianFight" -c "s32ArabianFight"
if not "%ERRORLEVEL%"=="0" goto :error

echo [4/4] Recording timing result (no assembler/RBF)...
powershell -NoProfile -ExecutionPolicy Bypass -File tools\report-quartus.ps1 ^
  -ProjectRoot "%CD%" -Revision "s32ArabianFight" ^
  -QuartusRoot "%QUARTUS_ROOT%" -ExpectedSeed 1 -RequireTiming
set "RESULT=%ERRORLEVEL%"
endlocal & exit /b %RESULT%

:no_quartus
echo ERROR: QUARTUS_ROOT is not set.
:error
endlocal & exit /b 1
