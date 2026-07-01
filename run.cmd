@echo off
rem Double-click launcher for run.ps1.
rem -ExecutionPolicy Bypass lets the script run on machines where .ps1
rem execution is disabled by policy; %~dp0 makes it work from any folder.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1"
if errorlevel 1 pause
