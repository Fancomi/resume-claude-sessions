# Windows PowerShell 5.1+; no Python dependency. Dot-source to use the functions.
[CmdletBinding()]
param(
    [Alias('CodexHome')][string]$DataHome,
    [string]$CodexCommand,
    [ValidateSet('wezterm', 'conhost', 'wt')][string]$TerminalHost = 'wezterm',
    [switch]$List,
    [switch]$AutoSelect,
    [switch]$DryRun,
    [switch]$IncludeSubagents,
    [switch]$SkipPermissions
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\wezterm.ps1')
. (Join-Path $PSScriptRoot 'scripts\session-picker.ps1')

function Test-CodexSubagent($Source) {
    if ($Source -is [string]) { return ($Source -replace '_', '') -match '^subagent' }
    if ($null -ne $Source) {
        foreach ($key in $Source.PSObject.Properties.Name) {
            if (($key -replace '_', '') -eq 'subagent') { return $true }
        }
    }
    return $false
}

function Get-CodexSessionFile([System.IO.FileInfo]$File, [switch]$IncludeSubagents) {
    $reader = $null
    $stream = $null
    try {
        # Allow Codex to keep writing while the picker reads metadata.
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($File.FullName, 'Open', 'Read', $share)
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
        for ($lineNumber = 0; $lineNumber -lt 64 -and -not $reader.EndOfStream; $lineNumber++) {
            $line = $reader.ReadLine()
            try { $record = ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue }
            if ($record.type -ne 'session_meta' -or $null -eq $record.payload) { continue }
            $meta = $record.payload
            if (-not $IncludeSubagents -and ((Test-CodexSubagent $meta.source) -or (Test-CodexSubagent $meta.thread_source))) { break }
            $id = if ($meta.id) { [string]$meta.id } else { [string]$meta.session_id }
            if (-not $id -and $File.BaseName -match '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$') { $id = $matches[1] }
            $parsedId = [guid]::Empty
            if (-not [guid]::TryParseExact($id, 'D', [ref]$parsedId)) { break }
            $cwd = $meta.cwd
            if ($cwd -isnot [string] -or -not [System.IO.Path]::IsPathRooted($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { break }
            return [pscustomobject]@{
                Id = $parsedId.ToString()
                Cwd = $cwd
                Name = $(if (Split-Path -Path $cwd -Leaf) { Split-Path -Path $cwd -Leaf } else { $cwd })
                LastSeen = $File.LastWriteTime
            }
        }
    } catch {
        # Skip files that disappeared, are unreadable, or contain invalid metadata.
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Add-CodexScannedSession($ById, $File, [switch]$IncludeSubagents) {
    $session = Get-CodexSessionFile -File $File -IncludeSubagents:$IncludeSubagents
    if ($null -ne $session -and (-not $ById.ContainsKey($session.Id) -or $session.LastSeen -gt $ById[$session.Id].LastSeen)) {
        $ById[$session.Id] = $session
    }
}

function Get-CodexSessions([string]$SessionsRoot, [switch]$IncludeSubagents) {
    if (-not (Test-Path -LiteralPath $SessionsRoot -PathType Container)) {
        throw "Sessions directory not found: $SessionsRoot"
    }
    $byId = @{}
    Get-ChildItem -LiteralPath $SessionsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
        Add-CodexScannedSession -ById $byId -File $_ -IncludeSubagents:$IncludeSubagents
    }
    $byId.Values | Sort-Object @{Expression='LastSeen'; Descending=$true}, Id
}

function Start-CodexSessionScan([string]$SessionsRoot, [bool]$IncludeSubagents, $Queue, $Control) {
    # A separate runspace keeps disk access and JSON parsing off the WinForms thread.
    $worker = [powershell]::Create()
    $scriptPath = $PSCommandPath
    $body = {
        param($ScriptPath, $Root, $IncludeAgents, $Queue, $Control)
        try {
            . $ScriptPath
            if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Sessions directory not found: $Root" }
            $byId = @{}
            $seen = @{}
            $older = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
            $cutoff = (Get-Date).AddDays(-3)
            $folders = @{}
            # Codex normally stores rollouts under their creation date in UTC.
            # Cover both local and UTC dates; older rollouts may still be active.
            foreach ($base in @((Get-Date).Date, (Get-Date).ToUniversalTime().Date)) {
                for ($day = 0; $day -le 3; $day++) {
                    $date = $base.AddDays(-$day)
                    $folder = Join-Path (Join-Path (Join-Path $Root $date.ToString('yyyy')) $date.ToString('MM')) $date.ToString('dd')
                    $folders[$folder] = $true
                }
            }
            foreach ($folder in $folders.Keys) {
                if ($Control.Cancelled) { throw [System.OperationCanceledException]::new() }
                if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
                Get-ChildItem -LiteralPath $folder -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($Control.Cancelled) { throw [System.OperationCanceledException]::new() }
                    if ($_.LastWriteTime -ge $cutoff) {
                        $seen[$_.FullName] = $true
                        Add-CodexScannedSession -ById $byId -File $_ -IncludeSubagents:$IncludeAgents
                    }
                }
            }
            $Queue.Enqueue([pscustomobject]@{ Kind='quick'; Sessions=@($byId.Values | Sort-Object @{Expression='LastSeen'; Descending=$true}, Id) })
            # An old creation-date directory can contain a recently resumed session.
            # Find those before reading the older files, regardless of folder layout.
            Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
                if ($Control.Cancelled) { throw [System.OperationCanceledException]::new() }
                if ($seen.ContainsKey($_.FullName)) { return }
                if ($_.LastWriteTime -ge $cutoff) {
                    Add-CodexScannedSession -ById $byId -File $_ -IncludeSubagents:$IncludeAgents
                } else { $older.Add($_) }
            }
            $Queue.Enqueue([pscustomobject]@{ Kind='recent'; Sessions=@($byId.Values | Sort-Object @{Expression='LastSeen'; Descending=$true}, Id) })
            foreach ($file in $older) {
                if ($Control.Cancelled) { throw [System.OperationCanceledException]::new() }
                Add-CodexScannedSession -ById $byId -File $file -IncludeSubagents:$IncludeAgents
            }
            $Queue.Enqueue([pscustomobject]@{ Kind='complete'; Sessions=@($byId.Values | Sort-Object @{Expression='LastSeen'; Descending=$true}, Id) })
        } catch [System.OperationCanceledException] {
            # Closing the picker cancels further work.
        } catch {
            $Queue.Enqueue([pscustomobject]@{ Kind='error'; Message=$_.Exception.Message })
        }
    }
    [void]$worker.AddScript($body.ToString()).AddArgument($scriptPath).AddArgument($SessionsRoot).AddArgument($IncludeSubagents).AddArgument($Queue).AddArgument($Control)
    $handle = $worker.BeginInvoke()
    return [pscustomobject]@{ PowerShell=$worker; Handle=$handle }
}

function Get-CodexRunningIds {
    $ids = @{}
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'codex.exe' OR Name = 'node.exe'" -ErrorAction Stop | ForEach-Object {
            if ($_.CommandLine -match '(?i)\bcodex(?:\.exe|\.js|\.cmd)?\b.*?\bresume\s+.*?([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})') {
                $ids[$matches[1].ToLowerInvariant()] = $true
            }
        }
    } catch { }
    return $ids
}

function New-CodexTabCommand($Session, [string]$Command, [string]$SessionHome, [switch]$Cli, [switch]$BypassPermissions) {
    $script = '$env:CODEX_HOME = ' + (ConvertTo-ResumeLiteral $SessionHome) + '; '
    $script += New-ResumeTabPrelude $Session.Cwd
    if (-not $Cli) {
        $script += '& ' + (ConvertTo-ResumeLiteral $Command)
        if ($BypassPermissions) { $script += ' --dangerously-bypass-approvals-and-sandbox' }
        else { $script += ' --sandbox danger-full-access --ask-for-approval never' }
        $script += ' resume ' + (ConvertTo-ResumeLiteral $Session.Id)
        $script += ' --no-daemon'
        $script += ' --cd ' + (ConvertTo-ResumeLiteral $Session.Cwd)
    }
    # Pass only ASCII arguments through Windows Terminal's command-line parser.
    [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
}

function Show-CodexSessionPicker([object[]]$Sessions, [hashtable]$RunningIds, [switch]$BuildOnly, [string]$SessionsRoot, [switch]$IncludeSubagents) {
    $scan = if ($SessionsRoot) {
        {
            param($queue, $control)
            Start-CodexSessionScan -SessionsRoot $SessionsRoot -IncludeSubagents ([bool]$IncludeSubagents) -Queue $queue -Control $control
        }
    }
    Show-ResumeSessionPicker -Provider 'Codex' -TerminalHost $TerminalHost -Sessions $Sessions -RunningIds $RunningIds -BuildOnly:$BuildOnly -StartScan $scan
}

function Invoke-CodexResume {
    Set-ResumeProxyEnvironment
    $sessionHome = $DataHome
    if (-not $sessionHome) { $sessionHome = $env:RESUME_CODEX_HOME }
    if (-not $sessionHome) { $sessionHome = $env:CODEX_HOME }
    if (-not $sessionHome) { $sessionHome = Join-Path $env:USERPROFILE '.codex' }
    $sessionHome = [System.IO.Path]::GetFullPath($sessionHome)
    $includeAgents = $IncludeSubagents -or $env:RESUME_INCLUDE_SUBAGENTS -eq '1'
    $sessionsRoot = Join-Path $sessionHome 'sessions'
    $preview = $DryRun -or $env:RESUME_DRY_RUN -eq '1'
    $automatic = $AutoSelect -or $env:RESUME_AUTO_SELECT -eq '1'
    # Noninteractive modes need a complete result before making a decision.
    $sessions = @()
    if ($List -or $automatic) { $sessions = @(Get-CodexSessions -SessionsRoot $sessionsRoot -IncludeSubagents:$includeAgents) }
    if ($List) { ConvertTo-Json -InputObject $sessions -Depth 4; return }
    if ($automatic -and $sessions.Count -eq 0) { Write-Host "没有找到可恢复的 Codex 会话：$sessionsRoot"; return }
    # Unattended by default, matching the macOS/Linux launcher.
    # RESUME_SKIP_PERMISSIONS=0 falls back to Codex's own defaults;
    # -SkipPermissions is still accepted as an explicit opt-in.
    $bypass = $true
    if ($env:RESUME_SKIP_PERMISSIONS -eq '0') { $bypass = $false }
    if ($SkipPermissions) { $bypass = $true }
    $command = $CodexCommand
    if (-not $command) { $command = $env:RESUME_CODEX_CMD }
    if (-not $command) {
        $found = Get-Command codex.exe,codex.cmd,codex.ps1,codex -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $command = $found.Source }
    }
    if (-not $command) {
        if ($preview) { $command = 'codex' }
        else { throw '找不到 Codex CLI。请安装 Codex CLI，或设置 RESUME_CODEX_CMD 为可执行文件路径。' }
    }
    $runningIds = Get-CodexRunningIds
    if ($automatic) {
        $latestDate = $sessions[0].LastSeen.Date
        $chosen = @($sessions | Where-Object { $_.LastSeen.Date -eq $latestDate -and -not $runningIds.ContainsKey($_.Id) } | ForEach-Object {
            [pscustomobject]@{ Session=$_; Group='1'; Cli=$false }
        })
    } else { $chosen = @(Show-CodexSessionPicker -Sessions $sessions -RunningIds $runningIds -SessionsRoot $sessionsRoot -IncludeSubagents:$includeAgents) }
    if ($chosen.Count -eq 0) { Write-Host '未选择任何会话。'; return }
    if ($preview) {
        foreach ($item in $chosen) {
            Write-Output ('[dry-run] G{0}  {1}  {2}' -f $item.Group, $item.Session.Id, $item.Session.Cwd)
            $encoded = New-CodexTabCommand -Session $item.Session -Command $command -SessionHome $sessionHome -BypassPermissions:$bypass
            Write-Output ([System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded)))
            if ($item.Cli) { Write-Output '  +CLI' }
        }
        return
    }
    Start-ResumeSessionWindows -Chosen $chosen -TerminalHost $TerminalHost -NewTabCommand {
        param($item, $cli)
        New-CodexTabCommand -Session $item.Session -Command $command -SessionHome $sessionHome -Cli:$cli -BypassPermissions:$bypass
    } -StartWezTerm { param($groups) Start-CodexWezTerm -Groups $groups }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-CodexResume }
    catch { Write-Error $_ -ErrorAction Continue; exit 1 }
}
