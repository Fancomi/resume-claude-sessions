# Resume Claude Code sessions. Lists ALL sessions grouped by date (newest first),
# with the most recent date group ticked by default.
# GUI: checkbox selection, group-into-one-window (tabs), optional CLI tab,
# auto-skip sessions that are already open.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$projectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
$claudeCmd    = Join-Path $env:APPDATA 'npm\claude.cmd'

function Show-Error($msg) {
    [System.Windows.Forms.MessageBox]::Show($msg, 'Claude Resume', 'OK', 'Error') | Out-Null
}

function Get-DateLabel($date) {
    $today = (Get-Date).Date
    $d     = $date.Date
    if     ($d -eq $today)             { "今天  ($($d.ToString('yyyy-MM-dd')))" }
    elseif ($d -eq $today.AddDays(-1)) { "昨天  ($($d.ToString('yyyy-MM-dd')))" }
    else   { $d.ToString('yyyy-MM-dd  dddd') }
}

if (-not (Test-Path $projectsRoot)) { Show-Error "Projects dir not found:`n$projectsRoot"; exit 1 }
if (-not (Test-Path $claudeCmd))    { $claudeCmd = 'claude' }  # fall back to PATH

# --- Discover ALL sessions ---------------------------------------------------
$sessions = @()
$files = Get-ChildItem -Path $projectsRoot -Recurse -Filter '*.jsonl' |
    Where-Object { $_.FullName -notmatch 'subagents' }

foreach ($f in $files) {
    $cwd = $null
    foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
        if (-not $line.Trim()) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (($o.PSObject.Properties.Name -contains 'cwd') -and $o.cwd) { $cwd = $o.cwd; break }
    }
    if (-not $cwd -or -not (Test-Path $cwd)) { continue }
    $sessions += [pscustomobject]@{
        Id       = $f.BaseName
        Cwd      = $cwd
        Name     = Split-Path $cwd -Leaf
        LastSeen = $f.LastWriteTime
    }
}
$sessions = $sessions | Sort-Object LastSeen -Descending

if ($sessions.Count -eq 0) { Show-Error 'No Claude sessions found.'; exit 0 }

# --- Detect already-running resumed sessions (by --resume <id> cmdline) -------
$runningIds = @{}
try {
    Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" | ForEach-Object {
        if ($_.CommandLine -match '--resume\s+([0-9a-fA-F-]{36})') { $runningIds[$matches[1]] = $true }
    }
} catch { }

# --- Group by date (newest first); newest group is ticked by default ---------
$newestDate = ($sessions | Select-Object -First 1).LastSeen.Date

# --- Build the selection form ------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude Code - Resume sessions (grouped by date)'
$form.Size = New-Object System.Drawing.Size(780, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = "所有会话按日期分组（由近到远），默认勾选最近一组。同一 GROUP 号 = 一个窗口多个标签页（0/留空 = 独立窗口）。" +
            "+CLI 额外开一个手动命令行标签页。已打开的会话默认不勾选。"
$lbl.SetBounds(12, 8, 740, 40)
$form.Controls.Add($lbl)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.SetBounds(12, 52, 740, 420)
$grid.Anchor = 'Top,Left,Right,Bottom'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'CellSelect'
$grid.AutoSizeColumnsMode = 'None'

$colOpen  = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colOpen.HeaderText = 'Open'; $colOpen.Width = 45
$colName  = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.HeaderText = 'Session (path)'; $colName.Width = 320; $colName.ReadOnly = $true
$colTime  = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colTime.HeaderText = 'Last active'; $colTime.Width = 120; $colTime.ReadOnly = $true
$colGroup = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colGroup.HeaderText = 'Group'; $colGroup.Width = 55
$colCli   = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colCli.HeaderText = '+CLI'; $colCli.Width = 45
$colState = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colState.HeaderText = 'Status'; $colState.Width = 110; $colState.ReadOnly = $true
$grid.Columns.AddRange($colOpen,$colName,$colTime,$colGroup,$colCli,$colState) | Out-Null
$form.Controls.Add($grid)

# Rows: insert a non-selectable header row per date group, then its sessions.
$headerBack = [System.Drawing.Color]::FromArgb(230, 236, 245)
$headerFore = [System.Drawing.Color]::FromArgb(30, 60, 110)
$i = 0
$grouped = $sessions | Group-Object { $_.LastSeen.Date } | Sort-Object { [datetime]$_.Name } -Descending
foreach ($g in $grouped) {
    $date = [datetime]$g.Name

    $isNewestGroup = ($date -eq $newestDate)

    # date header row (its checkbox toggles all sessions in the group)
    $hr = $grid.Rows.Add()
    $hrow = $grid.Rows[$hr]
    $hrow.Cells[0].Value = $isNewestGroup                # header checkbox = select-all for the group
    $hrow.Cells[1].Value = (Get-DateLabel $date) + "   —   $($g.Count) 个会话   （点左侧勾选框可全选/全不选本组）"
    $hrow.Cells[3].ReadOnly = $true
    $hrow.Cells[4].ReadOnly = $true
    $hrow.DefaultCellStyle.BackColor = $headerBack
    $hrow.DefaultCellStyle.ForeColor = $headerFore
    $hrow.DefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $hrow.Tag = 'HEADER'

    foreach ($s in ($g.Group | Sort-Object LastSeen -Descending)) {
        $isRunning = $runningIds.ContainsKey($s.Id)
        $status = if ($isRunning) { 'already open' } else { 'closed' }
        $isNewest = ($s.LastSeen.Date -eq $newestDate)
        $r = $grid.Rows.Add()
        $grid.Rows[$r].Cells[0].Value = ($isNewest -and -not $isRunning)   # tick newest group only
        $grid.Rows[$r].Cells[1].Value = $s.Cwd
        $grid.Rows[$r].Cells[2].Value = $s.LastSeen.ToString('MM-dd HH:mm')
        $grid.Rows[$r].Cells[3].Value = $i.ToString()                     # default: unique group per session
        $grid.Rows[$r].Cells[4].Value = $false                            # +CLI
        $grid.Rows[$r].Cells[5].Value = $status
        $grid.Rows[$r].Tag = $s
        $i++
    }
}

# Header checkbox toggles select-all / deselect-all for the sessions under it.
$grid.Add_CellValueChanged({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne 0) { return }
    $row = $sender.Rows[$e.RowIndex]
    if ($row.Tag -ne 'HEADER') { return }
    $check = ($row.Cells[0].Value -eq $true)
    for ($j = $e.RowIndex + 1; $j -lt $sender.Rows.Count; $j++) {
        $rr = $sender.Rows[$j]
        if ($rr.Tag -eq 'HEADER') { break }         # reached next date group
        $rr.Cells[0].Value = $check
    }
})
# Commit checkbox edits immediately so CellValueChanged fires on click.
$grid.Add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty) { $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
})

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = 'Open selected'
$btnOpen.SetBounds(580, 482, 110, 30)
$btnOpen.Anchor = 'Bottom,Right'
$btnOpen.DialogResult = 'OK'
$form.Controls.Add($btnOpen)
$form.AcceptButton = $btnOpen

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.SetBounds(700, 482, 60, 30)
$btnCancel.Anchor = 'Bottom,Right'
$btnCancel.DialogResult = 'Cancel'
$form.Controls.Add($btnCancel)
$form.CancelButton = $btnCancel

if ($form.ShowDialog() -ne 'OK') { exit 0 }

# --- Collect chosen rows (skip header rows) ----------------------------------
$chosen = @()
foreach ($row in $grid.Rows) {
    if ($row.Tag -eq 'HEADER' -or $null -eq $row.Tag) { continue }
    if ($row.Cells[0].Value -ne $true) { continue }
    $s = $row.Tag
    $grp = "$($row.Cells[3].Value)".Trim()
    if (-not $grp) { $grp = [guid]::NewGuid().ToString() }
    $chosen += [pscustomobject]@{
        Session = $s
        Group   = $grp
        Cli     = ($row.Cells[4].Value -eq $true)
    }
}
if ($chosen.Count -eq 0) { exit 0 }

# --- Launch: one Windows Terminal window per group, one tab per session ------
# (a group's rows collapse into tabs of a single wt window; +CLI adds a shell tab)
# Unattended by default, same as the macOS/Linux launcher; set
# RESUME_SKIP_PERMISSIONS=0 to keep Claude's normal permission prompts.
$dangerousArg = ' --dangerously-skip-permissions'
if ($env:RESUME_SKIP_PERMISSIONS -eq '0') { $dangerousArg = '' }
function Q($s) { '"' + ($s -replace '"','\"') + '"' }

$groups = $chosen | Group-Object Group
foreach ($g in $groups) {
    $wtArgs = New-Object System.Collections.Generic.List[string]
    $first = $true
    foreach ($item in $g.Group) {
        $s = $item.Session
        if (-not $first) { $wtArgs.Add(';') }
        $first = $false
        $resume = "$claudeCmd --resume $($s.Id)$dangerousArg"
        $wtArgs.AddRange([string[]]@('new-tab','--title',$s.Name,'-d',$s.Cwd,'cmd','/k',$resume))
        if ($item.Cli) {
            $wtArgs.Add(';')
            $wtArgs.AddRange([string[]]@('new-tab','--title',"$($s.Name)-cli",'-d',$s.Cwd,'cmd','/k','echo Manual CLI ready'))
        }
    }
    Start-Process wt -ArgumentList $wtArgs | Out-Null
    Start-Sleep -Milliseconds 500
}
