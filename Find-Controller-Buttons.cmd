@echo off
rem Shows connected controllers (VID/PID) and the number of each button you press.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0VrsProfileSwitcher.ps1" -ListControllers
