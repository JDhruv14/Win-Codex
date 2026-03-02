@echo off
setlocal

set SCRIPT=%~dp0scripts\run-superset.ps1
if not exist "%SCRIPT%" (
  echo Missing %SCRIPT%
  exit /b 1
)

if "%~1"=="" (
  echo Superset for Windows — convert a macOS DMG to a Windows app
  echo.
  echo Usage:
  echo   run-superset.cmd -DmgPath .\Superset.dmg
  echo.
  echo Options:
  echo   -DmgPath .\path\to\Superset.dmg   Path to the Superset DMG file
  echo   -WorkDir .\work-superset           Custom work directory
  echo   -Reuse                             Reuse previously extracted app
  echo   -BuildExe                          Build a portable Superset.exe
  echo   -NoLaunch                          Do not launch after building
  echo.
  echo Quick start:
  echo   1. Download Superset DMG from https://github.com/superset-sh/superset/releases
  echo   2. Place it in this folder as Superset.dmg
  echo   3. Run: run-superset.cmd -DmgPath .\Superset.dmg
  exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
