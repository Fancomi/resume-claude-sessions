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

function ConvertTo-CodexLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }

function New-CodexTabCommand($Session, [string]$Command, [string]$SessionHome, [switch]$Cli, [switch]$BypassPermissions) {
    $script = '$env:CODEX_HOME = ' + (ConvertTo-CodexLiteral $SessionHome) + '; '
    # Existing Windows Terminal processes can supply stale environment variables.
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        $literal = if ($null -eq $value) { '$null' } else { ConvertTo-CodexLiteral $value }
        $script += '$env:' + $name + ' = ' + $literal + '; '
    }
    $script += 'Set-Location -LiteralPath ' + (ConvertTo-CodexLiteral $Session.Cwd) + ' -ErrorAction Stop; '
    if (-not $Cli) {
        $script += '& ' + (ConvertTo-CodexLiteral $Command)
        if ($BypassPermissions) { $script += ' --dangerously-bypass-approvals-and-sandbox' }
        else { $script += ' --sandbox danger-full-access --ask-for-approval never' }
        $script += ' resume ' + (ConvertTo-CodexLiteral $Session.Id)
        $script += ' --no-daemon'
        $script += ' --cd ' + (ConvertTo-CodexLiteral $Session.Cwd)
    }
    # Pass only ASCII arguments through Windows Terminal's command-line parser.
    [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
}

function Get-CodexDateLabel([datetime]$Date) {
    if ($Date.Date -eq (Get-Date).Date) { return ('今天  ' + $Date.ToString('yyyy-MM-dd')) }
    if ($Date.Date -eq (Get-Date).Date.AddDays(-1)) { return ('昨天  ' + $Date.ToString('yyyy-MM-dd')) }
    return $Date.ToString('yyyy-MM-dd  dddd')
}

function Update-CodexPickerSessions($State, [object[]]$Sessions) {
    $grid = $State.Grid
    $previous = @{}
    foreach ($row in $grid.Rows) {
        if ($row.Tag -ne 'HEADER') {
            $previous[$row.Tag.Id] = @{
                Open=($row.Cells['Open'].Value -eq $true)
                Group=$row.Cells['Group'].Value
                Cli=($row.Cells['Cli'].Value -eq $true)
            }
        }
    }
    $State.Rebuilding = $true
    try {
        $grid.Rows.Clear()
        $latestDate = if ($Sessions.Count) { $Sessions[0].LastSeen.Date } else { $null }
        $lastDate = $null
        $header = $null
        $allChecked = $true
        foreach ($session in $Sessions) {
            $date = $session.LastSeen.Date
            $dateKey = $date.ToString('yyyy-MM-dd')
            if ($date -ne $lastDate) {
                if ($null -ne $header) { $header.Cells['Open'].Value = $allChecked }
                $lastDate = $date
                $allChecked = $true
                if (-not $State.DateGroups.ContainsKey($dateKey)) {
                    $State.NextGroup++
                    $State.DateGroups[$dateKey] = $State.NextGroup.ToString()
                }
                $header = $grid.Rows[$grid.Rows.Add()]
                $header.Tag = 'HEADER'
                $header.Cells['Cwd'].Value = Get-CodexDateLabel $date
                $header.Cells['Group'].ReadOnly = $true
                $header.Cells['Cli'].ReadOnly = $true
                $header.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(230, 236, 245)
            }
            $old = $previous[$session.Id]
            $row = $grid.Rows[$grid.Rows.Add()]
            $row.Tag = $session
            $isOpen = switch ($State.SelectionMode) {
                'all' { $true }
                'none' { $false }
                'custom' { $null -ne $old -and $old.Open }
                default { $date -eq $latestDate -and -not $State.RunningIds.ContainsKey($session.Id) }
            }
            $row.Cells['Open'].Value = $isOpen
            if (-not $isOpen) { $allChecked = $false }
            $row.Cells['Cwd'].Value = $session.Cwd + '  [' + $session.Id.Substring(0, 8) + ']'
            $row.Cells['Cwd'].ToolTipText = $session.Id
            $row.Cells['Time'].Value = $session.LastSeen.ToString('MM-dd HH:mm:ss')
            $row.Cells['Group'].Value = if ($null -ne $old) { $old.Group } else { $State.DateGroups[$dateKey] }
            $row.Cells['Cli'].Value = if ($null -ne $old) { $old.Cli } else { $false }
            $row.Cells['Status'].Value = $(if ($State.RunningIds.ContainsKey($session.Id)) { '已打开' } else { '可恢复' })
        }
        if ($null -ne $header) { $header.Cells['Open'].Value = $allChecked }
    } finally { $State.Rebuilding = $false }
}

function Show-CodexSessionPicker([object[]]$Sessions, [hashtable]$RunningIds, [switch]$BuildOnly, [string]$SessionsRoot, [switch]$IncludeSubagents) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Codex - 恢复会话（按日期分组）'
    $form.Size = New-Object System.Drawing.Size(1120, 680)
    $form.MinimumSize = New-Object System.Drawing.Size(850, 480)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = if ($TerminalHost -ne 'conhost') {
        '默认勾选最近日期的会话。相同的正整数分组 = 一个窗口多个标签页；0 / 留空 = 独立窗口。+CLI 额外打开命令行。'
    } else {
        '默认使用独立控制台，避开 Windows Terminal 切换窗口后的中文输入问题；每个会话单独开窗口。+CLI 另开命令行。'
    }
    $label.SetBounds(12, 12, 1080, 36)
    $label.Anchor = 'Top,Left,Right'
    $form.Controls.Add($label)
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.SetBounds(12, 52, 1080, 530)
    $grid.Anchor = 'Top,Left,Right,Bottom'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'CellSelect'
    $grid.AutoSizeColumnsMode = 'None'
    foreach ($spec in @(@('Open','开',45), @('Cwd','工作目录 / 会话 ID',570), @('Time','最后活动',140), @('Group','组',55), @('Cli','+CLI',55), @('Status','状态',90))) {
        if ($spec[0] -in @('Open', 'Cli')) { $column = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn }
        else { $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn }
        $column.Name = $spec[0]
        $column.HeaderText = $spec[1]
        $column.Width = $spec[2]
        $column.SortMode = 'NotSortable'
        $column.ReadOnly = $spec[0] -in @('Cwd', 'Time', 'Status')
        if ($spec[0] -eq 'Cwd') { $column.AutoSizeMode = 'Fill'; $column.MinimumWidth = 280 }
        [void]$grid.Columns.Add($column)
    }
    $form.Controls.Add($grid)
    $state = @{
        Grid=$grid; RunningIds=$RunningIds; Rebuilding=$false; SelectionMode='default'
        DateGroups=@{}; NextGroup=0; Queue=$null; Control=$null; Worker=$null; Pending=$null; ScanError=$null
    }
    $form.Tag = $state
    Update-CodexPickerSessions -State $state -Sessions $Sessions
    $grid.Add_CellValueChanged({
        param($sender, $eventArgs)
        if ($state.Rebuilding -or $eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -ne 0) { return }
        $state.SelectionMode = 'custom'
        $row = $sender.Rows[$eventArgs.RowIndex]
        if ($row.Tag -ne 'HEADER') { return }
        $state.Rebuilding = $true
        try {
            for ($index = $eventArgs.RowIndex + 1; $index -lt $sender.Rows.Count; $index++) {
                if ($sender.Rows[$index].Tag -eq 'HEADER') { break }
                $sender.Rows[$index].Cells['Open'].Value = ($row.Cells['Open'].Value -eq $true)
            }
        } finally { $state.Rebuilding = $false }
    })
    $grid.Add_CurrentCellDirtyStateChanged({
        if ($grid.IsCurrentCellDirty) { [void]$grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
    })
    $selectAll = New-Object System.Windows.Forms.Button
    $selectAll.Text = '全选'
    $selectAll.SetBounds(12, 598, 80, 30)
    $selectAll.Anchor = 'Bottom,Left'
    $selectAll.Add_Click({
        $state.Rebuilding = $true
        try { foreach ($row in $grid.Rows) { $row.Cells['Open'].Value = $true } }
        finally { $state.Rebuilding = $false }
        $state.SelectionMode = 'all'
    })
    $form.Controls.Add($selectAll)
    $selectNone = New-Object System.Windows.Forms.Button
    $selectNone.Text = '全不选'
    $selectNone.SetBounds(100, 598, 80, 30)
    $selectNone.Anchor = 'Bottom,Left'
    $selectNone.Add_Click({
        $state.Rebuilding = $true
        try { foreach ($row in $grid.Rows) { $row.Cells['Open'].Value = $false } }
        finally { $state.Rebuilding = $false }
        $state.SelectionMode = 'none'
    })
    $form.Controls.Add($selectNone)
    $status = New-Object System.Windows.Forms.Label
    $status.SetBounds(190, 604, 670, 24)
    $status.Anchor = 'Bottom,Left,Right'
    $status.Text = if ($SessionsRoot) { '正在扫描近 3 天的会话…' } else { '' }
    $form.Controls.Add($status)
    $open = New-Object System.Windows.Forms.Button
    $open.Text = '打开选中会话'
    $open.SetBounds(870, 598, 130, 30)
    $open.Anchor = 'Bottom,Right'
    $open.DialogResult = 'OK'
    $form.Controls.Add($open)
    $form.AcceptButton = $open
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.SetBounds(1010, 598, 80, 30)
    $cancel.Anchor = 'Bottom,Right'
    $cancel.DialogResult = 'Cancel'
    $form.Controls.Add($cancel)
    $form.CancelButton = $cancel
    if ($BuildOnly) { return $form }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
        $message = $null
        while ($state.Queue.TryDequeue([ref]$message)) {
            if ($message.Kind -eq 'error') {
                $state.ScanError = $message.Message
            } else { $state.Pending = $message }
            $message = $null
        }
        # A checkbox stays in edit mode while focused; only defer for a group
        # text edit so normal focus does not stop background results appearing.
        $editingGroup = $grid.IsCurrentCellInEditMode -and $null -ne $grid.CurrentCell -and $grid.CurrentCell.OwningColumn.Name -eq 'Group'
        if ($null -eq $state.Pending -or $editingGroup) {
            if ($state.ScanError) { $status.Text = '扫描失败：' + $state.ScanError }
            return
        }
        $message = $state.Pending
        $state.Pending = $null
        [void]$grid.EndEdit()
        Update-CodexPickerSessions -State $state -Sessions $message.Sessions
        $count = $message.Sessions.Count
        $status.Text = switch ($message.Kind) {
            'quick' { "已显示近期目录中的会话；正在后台扫描其他目录（$count 条）…" }
            'recent' { "近 3 天扫描完成；正在后台读取更早会话（$count 条）…" }
            'complete' { "扫描完成，共 $count 条会话。" }
        }
        if ($state.ScanError) { $status.Text = '扫描失败：' + $state.ScanError }
    })
    if ($SessionsRoot) {
        $form.Add_Shown({
            $state.Queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
            $state.Control = [hashtable]::Synchronized(@{ Cancelled=$false })
            try {
                $state.Worker = Start-CodexSessionScan -SessionsRoot $SessionsRoot -IncludeSubagents ([bool]$IncludeSubagents) -Queue $state.Queue -Control $state.Control
                $timer.Start()
            } catch { $status.Text = '无法启动扫描：' + $_.Exception.Message }
        })
    }
    try {
        if ($form.ShowDialog() -ne 'OK') { return }
        [void]$grid.EndEdit()
        foreach ($row in $grid.Rows) {
            if ($row.Tag -eq 'HEADER' -or $row.Cells['Open'].Value -ne $true) { continue }
            $groupText = ([string]$row.Cells['Group'].Value).Trim()
            $number = 0
            if ([int]::TryParse($groupText, [ref]$number) -and $number -gt 0) { $group = $number.ToString() }
            else { $group = 'single-' + $row.Tag.Id }
            [pscustomobject]@{ Session=$row.Tag; Group=$group; Cli=($row.Cells['Cli'].Value -eq $true) }
        }
    } finally {
        $timer.Stop()
        $timer.Dispose()
        if ($null -ne $state.Control) { $state.Control.Cancelled = $true }
        if ($null -ne $state.Worker) {
            try {
                if ($state.Worker.Handle.IsCompleted) {
                    [void]$state.Worker.PowerShell.EndInvoke($state.Worker.Handle)
                    $state.Worker.PowerShell.Dispose()
                } else { [void]$state.Worker.PowerShell.BeginStop($null, $null) }
            } catch { }
        }
        $form.Dispose()
    }
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
    $windowsTerminal = $null
    if ($TerminalHost -eq 'wt') {
        $windowsTerminal = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue
        if (-not $windowsTerminal) { throw '找不到 Windows Terminal；可使用默认 WezTerm 或 -TerminalHost conhost。' }
    }
    $weztermGroups = @()
    foreach ($group in ($chosen | Group-Object Group)) {
        $weztermTabs = @()
        $arguments = New-Object 'System.Collections.Generic.List[string]'
        $arguments.Add('-w')
        $arguments.Add('new')
        $first = $true
        foreach ($item in $group.Group) {
            $tabKinds = @($false)
            if ($item.Cli) { $tabKinds += $true }
            foreach ($cli in $tabKinds) {
                $encoded = New-CodexTabCommand -Session $item.Session -Command $command -SessionHome $sessionHome -Cli:$cli -BypassPermissions:$bypass
                $shellArgs = @('-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
                if ($TerminalHost -eq 'wezterm') {
                    $title = $item.Session.Name + ' - ' + $item.Session.Id.Substring(0, 8)
                    if ($cli) { $title += ' +CLI' }
                    $weztermTabs += [pscustomobject]@{
                        title=$title; cwd=$item.Session.Cwd; args=@('powershell.exe') + $shellArgs
                    }
                } elseif ($windowsTerminal) {
                    if (-not $first) { $arguments.Add(';') }
                    $first = $false
                    $title = ($item.Session.Name -replace '[^a-zA-Z0-9._-]', '_')
                    if ($title.Length -gt 32) { $title = $title.Substring(0, 32) }
                    $title += '-' + $item.Session.Id.Substring(0, 8)
                    if ($cli) { $title += '-cli' }
                    $arguments.AddRange([string[]]@('new-tab', '--title', $title, 'powershell.exe'))
                    $arguments.AddRange([string[]]$shellArgs)
                } else {
                    # Explicit conhost bypasses Windows' default terminal delegation.
                    $consoleHost = Join-Path $env:SystemRoot 'System32\conhost.exe'
                    Start-Process -FilePath $consoleHost -ArgumentList (@('powershell.exe') + $shellArgs) | Out-Null
                }
            }
        }
        if ($TerminalHost -eq 'wezterm') { $weztermGroups += [pscustomobject]@{name=$group.Name; tabs=@($weztermTabs)} }
        if ($windowsTerminal) { Start-Process -FilePath $windowsTerminal.Source -ArgumentList $arguments.ToArray() | Out-Null }
    }
    if ($weztermGroups.Count) { Start-CodexWezTerm -Groups $weztermGroups }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-CodexResume }
    catch { Write-Error $_ -ErrorAction Continue; exit 1 }
}
