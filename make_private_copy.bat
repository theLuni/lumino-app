@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0make_private_copy.ps1"
if errorlevel 1 (
  echo.
  echo Could not create the private copy. See the error above.
  pause
  exit /b 1
)
echo.
echo Your private working copy is ready.
pause
