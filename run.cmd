@echo off
setlocal

set SCRIPT=%~dp0scripts\run.ps1
if not exist "%SCRIPT%" (
  echo Missing %SCRIPT%
  exit /b 1
)

if "%~1"=="" (
  echo Usage:
  echo   run.cmd
  echo   run.cmd -DmgPath .\Codex.dmg
  echo Optional:
  echo   -WorkDir .\work  -CodexCliPath C:\path\to\codex.exe  -Reuse  -BuildExe
  exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
