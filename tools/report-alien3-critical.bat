@echo off
setlocal EnableExtensions

if /I "%S32_BUILD_LOCK_HELD%"=="1" if defined S32_BUILD_LOCK_TOKEN goto :locked
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0invoke-build-locked.ps1" -BuildScript "%~f0"
set "RESULT=%ERRORLEVEL%"
endlocal & exit /b %RESULT%

:locked
cd /d "%~dp0.."
if not "%ERRORLEVEL%"=="0" goto :error
if not defined QUARTUS_ROOT goto :missing_root
"%QUARTUS_ROOT%\quartus\bin64\quartus_sta.exe" -t tools\report-alien3-critical.tcl s32Alien3
set "RESULT=%ERRORLEVEL%"
endlocal & exit /b %RESULT%

:missing_root
echo ERROR: QUARTUS_ROOT is not set.
:error
endlocal & exit /b 1
