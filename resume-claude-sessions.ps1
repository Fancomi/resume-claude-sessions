# Windows PowerShell 5.1+. Dot-source to use the functions.
[CmdletBinding()]
param(
    [string]$ClaudeCommand,
    [ValidateSet('wezterm', 'conhost', 'wt')][string]$TerminalHost = 'wezterm'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\wezterm.ps1')
. (Join-Path $PSScriptRoot 'scripts\session-picker.ps1')

function Get-ClaudeTranscriptActivity([System.IO.FileInfo]$File) {
    # Claude appends records without a timestamp (cost-state and similar bookkeeping) at the end
    # of a transcript, often for several sessions at once, so the file's LastWriteTime drifts
    # away from real activity. Sort and display by the last record that does carry a timestamp.
    $stream = $null
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($File.FullName, 'Open', 'Read', $share)
        $size = $stream.Length
        if ($size -le 0) { return }
        $take = [Math]::Min($size, 65536)
        $stream.Seek($size - $take, 'Begin') | Out-Null
        $buffer = New-Object byte[] $take
        $read = $stream.Read($buffer, 0, $take)
        $lines = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read).Split("`n")
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            if ($lines[$index] -match '"timestamp":"([^"]+)"') {
                $parsed = [DateTimeOffset]::Parse($matches[1], [Globalization.CultureInfo]::InvariantCulture)
                return $parsed.LocalDateTime
            }
        }
    } catch {
        # Unreadable tails fall back to the file timestamp.
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-ClaudeSessionFile([System.IO.FileInfo]$File) {
    $reader = $null
    $stream = $null
    try {
        # A running Claude process can append to the transcript during discovery.
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($File.FullName, 'Open', 'Read', $share)
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if (-not $line.Trim()) { continue }
            try { $record = ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue }
            $cwd = $record.cwd
            if ($cwd -isnot [string] -or -not $cwd) { continue }
            if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { return }
            $name = Split-Path -Path $cwd -Leaf
            $activity = Get-ClaudeTranscriptActivity $File
            return [pscustomobject]@{
                Id=$File.BaseName; Cwd=$cwd; Name=$(if ($name) { $name } else { $cwd }); LastSeen=$(if ($null -ne $activity) { $activity } else { $File.LastWriteTime })
            }
        }
    } catch {
        # Skip unreadable files and files that disappear during the scan.
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Start-ClaudeSessionScan([string]$ProjectsRoot, $Queue, $Control) {
    $worker = [powershell]::Create()
    $body = {
        param($ScriptPath, $Root, $Queue, $Control)
        try {
            . $ScriptPath
            if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "找不到 Claude 会话目录：$Root" }
            $cutoff = (Get-Date).AddDays(-3)
            $older = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
            $byId = @{}
            # Claude stores logs by project, so prioritize by modification time.
            Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
                if ($Control.Cancelled) { throw [System.OperationCanceledException]::new() }
                if ($_.FullName.Substring($Root.Length) -match '(?:^|[\\/])subagents[\\/]') { return }
                if ($_.LastWriteTime -lt $cutoff) {
                    $older.Add($_)
                    return
                }
                $session = Get-ClaudeSessionFile $_
                if ($null -ne $session -and (-not $byId.ContainsKey($session.Id) -or $session.LastSeen -gt $byId[$session.Id].LastSeen)) {
                    $byId[$session.Id] = $session
                }
            }
            $order = @{Expression='LastSeen'; Descending=$true}
            $Queue.Enqueue([pscustomobject]@{ Kind='recent'; Sessions=@($byId.Values | Sort-Object $order, Id) })
            foreach ($file in ($older | Sort-Object LastWriteTime -Descending)) {
                if ($Control.Cancelled) { throw [System.OperationCanceledException]::new() }
                if ($byId.ContainsKey($file.BaseName)) { continue }
                $session = Get-ClaudeSessionFile $file
                if ($null -ne $session) { $byId[$session.Id] = $session }
            }
            $Queue.Enqueue([pscustomobject]@{ Kind='complete'; Sessions=@($byId.Values | Sort-Object $order, Id) })
        } catch [System.OperationCanceledException] {
            # Closing the picker cancels further work.
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Kind='error'; Message=$_.Exception.Message })
        }
    }
    [void]$worker.AddScript($body.ToString()).AddArgument($PSCommandPath).AddArgument($ProjectsRoot).AddArgument($Queue).AddArgument($Control)
    $handle = $worker.BeginInvoke()
    [pscustomobject]@{ PowerShell=$worker; Handle=$handle }
}

function Get-ClaudeRunningIds {
    $ids = @{}
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'claude.exe' OR Name = 'node.exe'" -ErrorAction Stop | ForEach-Object {
            if ($_.Name -eq 'node.exe' -and $_.CommandLine -notmatch '@anthropic-ai[\\/]claude-code[\\/]') { return }
            if ($_.CommandLine -match '(?:^|\s)--resume(?:\s+|=)["'']?([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})(?=$|[\s"''])') {
                $ids[$matches[1]] = $true
            }
        }
    } catch { }
    return $ids
}

function Resolve-ClaudeCommand([bool]$UseCustom, [string]$Value) {
    $extensions = @('.exe', '.com', '.cmd', '.bat', '.ps1')
    if ($UseCustom) {
        $value = $Value.Trim().Trim('"')
        if (-not $value) { throw '请输入替代命令名或程序路径，例如 claude-work.cmd。' }
        if ($value -match '[\\/]') {
            $file = Get-Item -LiteralPath $value -ErrorAction SilentlyContinue
            if ($file -is [IO.FileInfo] -and $file.Extension -in $extensions) { return $file.FullName }
        } else {
            $found = Get-Command -Name $value -CommandType Application,ExternalScript -ErrorAction SilentlyContinue |
                Where-Object {
                    [IO.Path]::GetExtension($_.Name) -in $extensions -and
                    ($_.Name -eq $value -or [IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $value)
                } | Select-Object -First 1
            if ($found) { return $found.Source }
        }
        throw "找不到替代命令：$value。请输入 PATH 中的命令名或 .exe、.com、.cmd、.bat、.ps1 路径。"
    }

    $npmCommand = Join-Path $env:APPDATA 'npm\claude.cmd'
    if (Test-Path -LiteralPath $npmCommand -PathType Leaf) { return $npmCommand }
    $found = Get-Command -Name claude.exe,claude.cmd,claude.ps1,claude.bat -CommandType Application,ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.Source }
    throw '找不到 claude。请安装 Claude Code，或勾选“用其他命令代替 claude”并输入启动命令。'
}

function New-ClaudeTabCommand($Session, [string]$Command, [switch]$Cli, [switch]$BypassPermissions) {
    $script = New-ResumeTabPrelude $Session.Cwd
    if (-not $Cli) {
        $script += '& ' + (ConvertTo-ResumeLiteral $Command) + ' --resume ' + (ConvertTo-ResumeLiteral $Session.Id)
        if ($BypassPermissions) { $script += ' --dangerously-skip-permissions' }
    }
    [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
}

function Invoke-ClaudeResume {
    $projectsRoot = $env:RESUME_PROJECTS_ROOT
    if (-not $projectsRoot) { $projectsRoot = Join-Path $env:USERPROFILE '.claude\projects' }
    $projectsRoot = [IO.Path]::GetFullPath($projectsRoot)
    $chosen = @(Show-ResumeSessionPicker -Provider 'Claude Code' -TerminalHost $TerminalHost -Sessions @() -RunningIds (Get-ClaudeRunningIds) -StartScan {
        param($queue, $control)
        Start-ClaudeSessionScan -ProjectsRoot $projectsRoot -Queue $queue -Control $control
    } -InitialCommand $ClaudeCommand -ResolveCommand {
        param($useCustom, $value)
        Resolve-ClaudeCommand -UseCustom $useCustom -Value $value
    })
    if ($chosen.Count -eq 0) { return }

    $bypass = $env:RESUME_SKIP_PERMISSIONS -ne '0'
    Start-ResumeSessionWindows -Chosen $chosen -TerminalHost $TerminalHost -NewTabCommand {
        param($item, $cli)
        New-ClaudeTabCommand -Session $item.Session -Command $item.Command -Cli:$cli -BypassPermissions:$bypass
    } -StartWezTerm { param($groups) Start-ResumeWezTerm -Groups $groups -Provider 'Claude' }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-ClaudeResume }
    catch { Write-Error $_ -ErrorAction Continue; exit 1 }
}
