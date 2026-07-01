@echo off
rem Double-click launcher for deploy.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1"
if errorlevel 1 pause
