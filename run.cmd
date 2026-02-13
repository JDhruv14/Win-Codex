@echo off
setlocal

set SCRIPT=%~dp0scripts\run.ps1
if not exist "%SCRIPT%" (
  echo Missing %SCRIPT%
  exit /b 1
)

if /I "%~1"=="-h" goto :usage
if /I "%~1"=="--help" goto :usage
if /I "%~1"=="/?" goto :usage

if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
  exit /b %errorlevel%
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %errorlevel%

:usage
echo Usage:
echo   run.cmd
echo   run.cmd -DmgPath .\Codex.dmg
echo Optional:
echo   -WorkDir .\work  -CodexCliPath C:\path\to\codex.exe  -Reuse  -BuildExe -NoLaunch
exit /b 0
