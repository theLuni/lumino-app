@echo off
setlocal
cd /d "%~dp0"

echo.
echo Lumino Windows release builder
for /f "tokens=2" %%V in ('findstr /r /c:"^version:" "%~dp0pubspec.yaml"') do echo Current version: %%V
echo Enter a version such as 0.3.3, or press Enter to increase the patch version.
echo.
set "LUMINO_VERSION="
set /p "LUMINO_VERSION=New version: "

if defined LUMINO_VERSION (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_release.ps1" -Version "%LUMINO_VERSION%"
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_release.ps1"
)

if errorlevel 1 (
  echo.
  echo Release build failed. Read the error above.
  pause
  exit /b 1
)

echo.
echo Build and version report completed.
pause
