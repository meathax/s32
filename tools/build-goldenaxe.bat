@echo off
setlocal EnableExtensions

REM Acquire the repository build mutex before regenerating the dedicated QSF.
if /I "%S32_BUILD_LOCK_HELD%"=="1" if defined S32_BUILD_LOCK_TOKEN goto :build_lock_acquired
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0invoke-build-locked.ps1" -BuildScript "%~f0"
set "LOCK_RESULT=%ERRORLEVEL%"
endlocal & exit /b %LOCK_RESULT%

:build_lock_acquired
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-goldenaxe-qsf.ps1"
set "SYNC_RESULT=%ERRORLEVEL%"
if not "%SYNC_RESULT%"=="0" goto :sync_failed

set "S32_PROJECT=s32GoldenAxe"
set "S32_REVISION=s32GoldenAxe"
set "S32_RELEASE_NAME=s32GoldenAxe"
call "%~dp0build.bat"
set "BUILD_RESULT=%ERRORLEVEL%"
endlocal & exit /b %BUILD_RESULT%

:sync_failed
endlocal & exit /b %SYNC_RESULT%
