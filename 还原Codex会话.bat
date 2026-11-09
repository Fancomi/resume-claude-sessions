@echo off
setlocal
chcp 65001 >nul
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0resume-codex-sessions.ps1" %*
if errorlevel 1 pause
