@echo off
setlocal
chcp 65001 >nul
rem 双击运行时先选择打开方式；带参数时（例如 -TerminalHost wt）直接透传，不再询问。
if not "%~1"=="" goto launch
echo.
echo  选择打开方式（5 秒内不选将使用 WezTerm）：
echo    [1] WezTerm           同一组的会话在一个窗口内以标签页打开
echo    [2] Windows Terminal  同样支持标签页，标签里运行 PowerShell
choice /c 12 /n /t 5 /d 1 /m "  按 1 或 2 选择："
if errorlevel 2 (
    where wt.exe >nul 2>nul
    if errorlevel 1 (
        echo  未找到 Windows Terminal，改用独立 PowerShell 窗口。
        set "HOST=-TerminalHost conhost"
    ) else (
        set "HOST=-TerminalHost wt"
    )
) else (
    set "HOST=-TerminalHost wezterm"
)
:launch
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0resume-claude-sessions.ps1" %HOST% %*
if errorlevel 1 pause
