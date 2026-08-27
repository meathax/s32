@echo off
setlocal
where py >nul 2>nul
if not errorlevel 1 goto :use_py
where python >nul 2>nul
if errorlevel 1 (
  echo Python 3.10 or newer was not found. 1>&2
  exit /b 9009
)
python "%~dp0mister.py" %*
exit /b %errorlevel%

:use_py
py -3 "%~dp0mister.py" %*
exit /b %errorlevel%
