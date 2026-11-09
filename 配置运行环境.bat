@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\wezterm.ps1" %*
set "setup_exit=%errorlevel%"
pause
exit /b %setup_exit%
