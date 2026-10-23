@echo off
rem Runs the button listener in a visible window (for testing). Needs PowerShell 7: winget install Microsoft.PowerShell
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0VrsProfileSwitcher.ps1" %*
pause
