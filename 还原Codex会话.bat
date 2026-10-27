@echo off
setlocal
chcp 65001 >nul
set "HTTP_PROXY=http://127.0.0.1:7890"
set "HTTPS_PROXY=http://127.0.0.1:7890"
set "ALL_PROXY=http://127.0.0.1:7890"
set "NO_PROXY=localhost,127.0.0.1,::1,%NO_PROXY%"
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0resume-codex-sessions.ps1" %*
if errorlevel 1 pause
