"""Exercise staged Windows discovery and its live picker with isolated rollouts."""

import base64
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
POWERSHELL = shutil.which("powershell.exe") if os.name == "nt" else None
SCRIPT = ROOT / "resume-codex-sessions.ps1"


def ps_literal(value):
    return "'" + str(value).replace("'", "''") + "'"


@unittest.skipUnless(POWERSHELL, "Windows PowerShell is required")
class StagedWindowsCodexTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="resume-codex-test-"))
        self.addCleanup(self.remove_fixture)
        self.home = self.root / "codex"
        self.sessions = self.home / "sessions"
        self.sessions.mkdir(parents=True)
        self.work = self.root / "work"
        self.work.mkdir()

    def remove_fixture(self):
        target = ps_literal(self.root)
        # Verify the generated fixture root once, then remove only that tree.
        preflight = (
            f"$item = Get-Item -LiteralPath {target} -Force -ErrorAction Stop; "
            "if ($item.LinkType -or -not $item.FullName.StartsWith("
            "[System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()), "
            "[System.StringComparison]::OrdinalIgnoreCase)) { exit 2 }"
        )
        subprocess.run([POWERSHELL, "-NoProfile", "-Command", preflight], check=True, capture_output=True)
        subprocess.run(
            [POWERSHELL, "-NoProfile", "-Command", f"Remove-Item -LiteralPath {target} -Recurse -Force -ErrorAction Stop"],
            check=True,
            capture_output=True,
        )

    def write_rollout(self, identifier, creation_date, age_seconds=0, source="cli"):
        folder = self.sessions / creation_date.strftime("%Y/%m/%d")
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"rollout-{identifier}.jsonl"
        record = {"type": "session_meta", "payload": {"id": identifier, "cwd": str(self.work), "source": source}}
        path.write_text(json.dumps(record) + "\n", encoding="utf-8")
        modified = time.time() - age_seconds
        os.utime(path, (modified, modified))
        return path

    def run_powershell(self, source, timeout=30):
        source = "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)\n" + source
        encoded = base64.b64encode(source.encode("utf-16-le")).decode("ascii")
        result = subprocess.run(
            [POWERSHELL, "-NoProfile", "-STA", "-NonInteractive", "-EncodedCommand", encoded],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_recent_sessions_precede_old_files_even_in_old_directories(self):
        now = dt.datetime.now(dt.timezone.utc)
        today = now.date()
        old_day = today - dt.timedelta(days=30)
        fresh = "11111111-1111-4111-8111-111111111111"
        resumed = "22222222-2222-4222-8222-222222222222"
        old = "33333333-3333-4333-8333-333333333333"
        agent = "44444444-4444-4444-8444-444444444444"
        self.write_rollout(fresh, today)
        self.write_rollout(resumed, old_day, age_seconds=60)
        self.write_rollout(old, old_day, age_seconds=5 * 86400)
        self.write_rollout(agent, today, source="subagent")
        stale = self.write_rollout(fresh, old_day - dt.timedelta(days=1), age_seconds=6 * 86400)
        stale_work = self.root / "stale-work"
        stale_work.mkdir()
        stale.write_text(json.dumps({"type": "session_meta", "payload": {"id": fresh, "cwd": str(stale_work)}}) + "\n", encoding="utf-8")
        stale_time = time.time() - 6 * 86400
        os.utime(stale, (stale_time, stale_time))
        source = f"""
$ErrorActionPreference = 'Stop'
. {ps_literal(SCRIPT)}
$queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$control = [hashtable]::Synchronized(@{{Cancelled=$false}})
$worker = Start-CodexSessionScan -SessionsRoot {ps_literal(self.sessions)} -IncludeSubagents $false -Queue $queue -Control $control
try {{
    while (-not $worker.Handle.IsCompleted) {{ Start-Sleep -Milliseconds 20 }}
    [void]$worker.PowerShell.EndInvoke($worker.Handle)
    $events = @()
    $entry = $null
    while ($queue.TryDequeue([ref]$entry)) {{
        if ($entry.Kind -eq 'error') {{ throw $entry.Message }}
        $events += [pscustomobject]@{{ kind=$entry.Kind; ids=@($entry.Sessions | ForEach-Object {{ $_.Id }}); names=@($entry.Sessions | ForEach-Object {{ $_.Name }}) }}
        $entry = $null
    }}
    ConvertTo-Json -InputObject $events -Depth 5 -Compress
}} finally {{ $worker.PowerShell.Dispose() }}
"""
        events = json.loads(self.run_powershell(source))
        self.assertEqual([event["kind"] for event in events], ["quick", "recent", "complete"])
        self.assertEqual(events[0]["ids"], [fresh])
        self.assertEqual(set(events[1]["ids"]), {fresh, resumed})
        self.assertEqual(set(events[2]["ids"]), {fresh, resumed, old})
        self.assertEqual(len(events[2]["ids"]), 3)
        self.assertNotIn("stale-work", events[2]["names"])

    def test_picker_loads_in_background_and_keeps_user_choices(self):
        today = dt.datetime.now(dt.timezone.utc).date()
        old_day = today - dt.timedelta(days=30)
        recent = "11111111-1111-4111-8111-111111111111"
        self.write_rollout(recent, today)
        for number in range(400):
            self.write_rollout(f"00000000-0000-4000-8000-{number:012x}", old_day, age_seconds=5 * 86400)
        source = f"""
$ErrorActionPreference = 'Stop'
. {ps_literal(SCRIPT)}
Add-Type -AssemblyName System.Windows.Forms
$probe = @{{ Ticks=0; Edited=$false; EditedWhileScanning=$false; Result='timeout'; Open=$null; Group=$null; Cli=$null; OtherOpen=0; Count=0 }}
$observer = New-Object System.Windows.Forms.Timer
$observer.Interval = 100
$observer.Add_Tick({{
    $probe.Ticks++
    $form = [System.Windows.Forms.Application]::OpenForms | Select-Object -First 1
    if ($null -eq $form) {{ return }}
    $form.Opacity = 0
    $state = $form.Tag
    $row = $state.Grid.Rows | Where-Object {{ $_.Tag -ne 'HEADER' -and $_.Tag.Id -eq '{recent}' }} | Select-Object -First 1
    if (-not $probe.Edited -and $null -ne $row) {{
        $probe.EditedWhileScanning = -not $state.Worker.Handle.IsCompleted
        $row.Cells['Open'].Value = $false
        $row.Cells['Group'].Value = '42'
        $row.Cells['Cli'].Value = $true
        $probe.Edited = $true
    }}
    $labels = @($form.Controls | Where-Object {{ $_ -is [System.Windows.Forms.Label] }})
    if ($labels.Count -gt 1 -and $labels[1].Text -match '^(扫描完成|扫描失败|无法启动扫描)') {{
        $probe.Result = $labels[1].Text
        $row = $state.Grid.Rows | Where-Object {{ $_.Tag -ne 'HEADER' -and $_.Tag.Id -eq '{recent}' }} | Select-Object -First 1
        if ($null -ne $row) {{
            $probe.Open = $row.Cells['Open'].Value
            $probe.Group = $row.Cells['Group'].Value
            $probe.Cli = $row.Cells['Cli'].Value
        }}
        $allRows = @($state.Grid.Rows | Where-Object {{ $_.Tag -ne 'HEADER' }})
        $probe.Count = $allRows.Count
        $probe.OtherOpen = @($allRows | Where-Object {{ $_.Tag.Id -ne '{recent}' -and $_.Cells['Open'].Value -eq $true }}).Count
        $form.Close()
    }} elseif ($probe.Ticks -gt 250) {{ $form.Close() }}
}})
$observer.Start()
try {{ @(Show-CodexSessionPicker -Sessions @() -RunningIds @{{}} -SessionsRoot {ps_literal(self.sessions)}) | Out-Null }}
finally {{ $observer.Stop(); $observer.Dispose() }}
ConvertTo-Json -InputObject $probe -Compress
"""
        result = json.loads(self.run_powershell(source, timeout=40))
        self.assertTrue(result["Result"].startswith("扫描完成"), result)
        self.assertTrue(result["EditedWhileScanning"], result)
        self.assertEqual(result["Count"], 401)
        self.assertFalse(result["Open"])
        self.assertEqual(result["Group"], "42")
        self.assertTrue(result["Cli"])
        self.assertEqual(result["OtherOpen"], 0)

    def test_noninteractive_modes_use_complete_discovery(self):
        today = dt.datetime.now(dt.timezone.utc).date()
        old_day = today - dt.timedelta(days=30)
        recent = "11111111-1111-4111-8111-111111111111"
        old = "22222222-2222-4222-8222-222222222222"
        self.write_rollout(recent, old_day)
        self.write_rollout(old, old_day, age_seconds=5 * 86400)
        listing = self.run_powershell(f"& {ps_literal(SCRIPT)} -DataHome {ps_literal(self.home)} -List")
        self.assertEqual({item["Id"] for item in json.loads(listing)}, {recent, old})
        preview = self.run_powershell(
            f"& {ps_literal(SCRIPT)} -DataHome {ps_literal(self.home)} -AutoSelect -DryRun -CodexCommand 'fake-codex.exe'"
        )
        self.assertIn(recent, preview)
        self.assertNotIn(old, preview)


if __name__ == "__main__":
    unittest.main()
