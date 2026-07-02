@echo off
rem Double-click launcher for publish.ps1 (push to origin, then deploy).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish.ps1"
if errorlevel 1 pause
