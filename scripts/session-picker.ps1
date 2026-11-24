# Windows PowerShell 5.1+. Shared Claude and Codex WinForms session picker.
function Get-ResumeDateLabel([datetime]$Date) {
    if ($Date.Date -eq (Get-Date).Date) { return ('今天  ' + $Date.ToString('yyyy-MM-dd')) }
    if ($Date.Date -eq (Get-Date).Date.AddDays(-1)) { return ('昨天  ' + $Date.ToString('yyyy-MM-dd')) }
    return $Date.ToString('yyyy-MM-dd  dddd')
}

function Update-ResumePickerSessions($State, [object[]]$Sessions) {
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
                $header.Cells['Cwd'].Value = Get-ResumeDateLabel $date
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
            $shortId = $session.Id.Substring(0, [Math]::Min(8, $session.Id.Length))
            $row.Cells['Cwd'].Value = $session.Cwd + '  [' + $shortId + ']'
            $row.Cells['Cwd'].ToolTipText = $session.Id
            $row.Cells['Time'].Value = $session.LastSeen.ToString('MM-dd HH:mm:ss')
            $row.Cells['Group'].Value = if ($null -ne $old) { $old.Group } else { $State.DateGroups[$dateKey] }
            $row.Cells['Cli'].Value = if ($null -ne $old) { $old.Cli } else { $false }
            $row.Cells['Status'].Value = $(if ($State.RunningIds.ContainsKey($session.Id)) { '已打开' } else { '可恢复' })
        }
        if ($null -ne $header) { $header.Cells['Open'].Value = $allChecked }
    } finally { $State.Rebuilding = $false }
}

function Show-ResumeSessionPicker {
    param(
        [string]$Provider,
        [string]$TerminalHost,
        [object[]]$Sessions,
        [hashtable]$RunningIds,
        [switch]$BuildOnly,
        [scriptblock]$StartScan,
        [string]$InitialCommand,
        [scriptblock]$ResolveCommand
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$Provider - 恢复会话（按日期分组）"
    $form.Size = New-Object System.Drawing.Size(1120, 680)
    $form.MinimumSize = New-Object System.Drawing.Size(850, 480)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = if ($TerminalHost -ne 'conhost') {
        '默认勾选最近日期的会话。相同的正整数分组 = 一个窗口多个标签页；0 / 留空 = 独立窗口。+CLI 额外打开命令行。'
    } else {
        '使用独立控制台，每个会话单独开窗口。+CLI 另开命令行。'
    }
    $label.SetBounds(12, 12, 1080, 36)
    $label.Anchor = 'Top,Left,Right'
    $form.Controls.Add($label)
    $gridTop = 52
    if ($ResolveCommand) {
        $useCustomCommand = New-Object System.Windows.Forms.CheckBox
        $useCustomCommand.Name = 'UseCustomCommand'
        $useCustomCommand.Text = '用其他命令代替 claude'
        $useCustomCommand.SetBounds(12, 48, 170, 25)
        $useCustomCommand.Checked = -not [string]::IsNullOrWhiteSpace($InitialCommand)
        $form.Controls.Add($useCustomCommand)

        $commandInput = New-Object System.Windows.Forms.TextBox
        $commandInput.Name = 'CommandInput'
        $commandInput.AccessibleName = '替代启动命令或可执行文件路径'
        $commandInput.SetBounds(188, 49, 904, 25)
        $commandInput.Anchor = 'Top,Left,Right'
        $commandInput.Text = $InitialCommand
        $commandInput.Enabled = $useCustomCommand.Checked
        $form.Controls.Add($commandInput)
        $useCustomCommand.Add_CheckedChanged({
            $commandInput.Enabled = $useCustomCommand.Checked
            if ($commandInput.Enabled) { [void]$commandInput.Focus() }
        })
        $gridTop = 83
    }
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.SetBounds(12, $gridTop, 1080, (582 - $gridTop))
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
    Update-ResumePickerSessions -State $state -Sessions $Sessions
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
    $status.Text = if ($StartScan) { '正在扫描近 3 天的会话…' } else { '' }
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
    if ($ResolveCommand) {
        $form.Add_FormClosing({
            param($sender, $eventArgs)
            if ($sender.DialogResult -ne 'OK') { return }
            [void]$grid.EndEdit()
            $selected = $grid.Rows | Where-Object { $_.Tag -ne 'HEADER' -and $_.Cells['Open'].Value -eq $true } | Select-Object -First 1
            if ($null -eq $selected) { return }
            try {
                $state.Command = & $ResolveCommand $useCustomCommand.Checked $commandInput.Text
            } catch {
                $eventArgs.Cancel = $true
                $sender.DialogResult = 'None'
                [void][System.Windows.Forms.MessageBox]::Show($sender, $_.Exception.Message, $Provider, 'OK', 'Error')
                if ($commandInput.Enabled) { [void]$commandInput.Focus() }
            }
        })
    }
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
        Update-ResumePickerSessions -State $state -Sessions $message.Sessions
        $count = $message.Sessions.Count
        $status.Text = switch ($message.Kind) {
            'quick' { "已显示近期目录中的会话；正在后台扫描其他目录（$count 条）…" }
            'recent' { "近 3 天扫描完成；正在后台读取更早会话（$count 条）…" }
            'complete' { "扫描完成，共 $count 条会话。" }
        }
        if ($state.ScanError) { $status.Text = '扫描失败：' + $state.ScanError }
    })
    if ($StartScan) {
        $form.Add_Shown({
            $state.Queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
            $state.Control = [hashtable]::Synchronized(@{ Cancelled=$false })
            try {
                $state.Worker = & $StartScan $state.Queue $state.Control
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
            $selection = @{ Session=$row.Tag; Group=$group; Cli=($row.Cells['Cli'].Value -eq $true) }
            if ($ResolveCommand) { $selection.Command = $state.Command }
            [pscustomobject]$selection
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
