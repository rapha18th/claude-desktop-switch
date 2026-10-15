@echo off
rem Double-click to set up Claude Desktop Switch, or to refresh its shortcuts.
if not exist "%~dp0ClaudeSwitch.ps1" (
  echo Extract the zip first ^(right-click, Extract All^), then run Setup.cmd from the extracted folder.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClaudeSwitch.ps1" setup
if errorlevel 1 pause
