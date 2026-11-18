"""Exercise Windows host selection without scanning or opening real sessions."""

import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
POWERSHELL = shutil.which("powershell.exe") if os.name == "nt" else None


@unittest.skipUnless(POWERSHELL, "Windows PowerShell is required")
class WindowsCodexLauncherTests(unittest.TestCase):
    def launch(self, host=None, separate=False):
        script_path = str(ROOT / "resume-codex-sessions.ps1").replace("'", "''")
        script = f"$ErrorActionPreference = 'Stop'\n. '{script_path}'"
        if host:
            script += f" -TerminalHost {host}"
        script += r"""
$CodexCommand = 'fake-codex.exe'
$DataHome = 'C:\fixture-codex-home'
$env:RESUME_AUTO_SELECT = '0'
$env:RESUME_DRY_RUN = '0'
$env:RESUME_SKIP_PERMISSIONS = $null
$env:RESUME_PROXY = $null
$env:HTTP_PROXY = $env:HTTPS_PROXY = $env:ALL_PROXY = 'http://127.0.0.1:17890'
$env:NO_PROXY = 'localhost,127.0.0.1'
$script:launches = New-Object 'System.Collections.Generic.List[object]'
$script:weztermGroups = @()
function Start-CodexWezTerm {
    param($Groups)
    $script:weztermGroups = @($Groups)
}
function Start-Process {
    param($FilePath, $ArgumentList)
    $script:launches.Add([pscustomobject]@{ File=$FilePath; Arguments=$ArgumentList })
}
function Get-Command {
    param($Name, $CommandType, $ErrorAction)
    if ($Name -ne 'wt.exe') { throw 'Unexpected executable lookup' }
    [pscustomobject]@{ Source='C:\fixture\wt.exe' }
}
function Get-CodexSessions {
    [pscustomobject]@{ Id='11111111-1111-4111-8111-111111111111'; Cwd="C:\test space's"; Name='one'; LastSeen=(Get-Date) }
    [pscustomobject]@{ Id='22222222-2222-4222-8222-222222222222'; Cwd='C:\test-two'; Name='two'; LastSeen=(Get-Date) }
}
function Get-CodexRunningIds { return @{} }
function Show-CodexSessionPicker {
    param($Sessions, $RunningIds, $SessionsRoot, $IncludeSubagents)
    if (@($Sessions).Count -ne 0) { throw 'Interactive picker must start without a full scan' }
    $Sessions = @(Get-CodexSessions)
    [pscustomobject]@{ Session=$Sessions[0]; Group='1'; Cli=$true }
    $secondGroup = if ($script:separate) { 'single-two' } else { '1' }
    [pscustomobject]@{ Session=$Sessions[1]; Group=$secondGroup; Cli=$false }
}
"""
        script += f"$script:separate = ${str(separate).lower()}\n"
        script += r"""
Invoke-CodexResume
ConvertTo-Json -InputObject @{ launches=@($script:launches.ToArray()); groups=@($script:weztermGroups) } -Depth 8 -Compress
"""
        encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
        result = subprocess.run(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def decoded_commands(self, launches):
        commands = []
        for launch in launches:
            arguments = launch["Arguments"]
            for index, argument in enumerate(arguments):
                if argument == "-EncodedCommand":
                    commands.append(base64.b64decode(arguments[index + 1]).decode("utf-16-le"))
        return commands

    def assert_session_commands(self, launches):
        commands = self.decoded_commands(launches)
        self.assertEqual(len(commands), 3)
        resumed = [command for command in commands if " resume " in command]
        self.assertEqual(len(resumed), 2)
        for command in resumed:
            self.assertIn("--no-daemon", command)
            self.assertIn("--dangerously-bypass-approvals-and-sandbox", command)
        for command in commands:
            self.assertIn("$env:CODEX_HOME = 'C:\\fixture-codex-home'", command)
            self.assertIn("http://127.0.0.1:17890", command)
        self.assertIn("Set-Location -LiteralPath 'C:\\test space''s'", commands[0])

    def test_default_opens_grouped_wezterm_tabs_with_cli(self):
        result = self.launch()
        self.assertEqual(result["launches"], [])
        self.assertEqual(len(result["groups"]), 1)
        tabs = result["groups"][0]["tabs"]
        self.assertEqual(len(tabs), 3)
        self.assert_session_commands([{"Arguments": tab["args"]} for tab in tabs])

    def test_independent_group_gets_its_own_wezterm_window(self):
        result = self.launch(separate=True)
        self.assertEqual([len(group["tabs"]) for group in result["groups"]], [2, 1])

    def test_console_host_opt_in_opens_independent_windows(self):
        launches = self.launch("conhost")["launches"]
        self.assertEqual(len(launches), 3)
        for launch in launches:
            self.assertEqual(Path(launch["File"]).name.lower(), "conhost.exe")
            self.assertEqual(launch["Arguments"][0], "powershell.exe")
        self.assert_session_commands(launches)

    def test_windows_terminal_opt_in_retains_grouped_tabs(self):
        launches = self.launch("wt")["launches"]
        self.assertEqual(len(launches), 1)
        self.assertEqual(launches[0]["File"], "C:\\fixture\\wt.exe")
        self.assertEqual(launches[0]["Arguments"].count("new-tab"), 3)
        self.assertEqual(launches[0]["Arguments"][:2], ["-w", "new"])
        self.assert_session_commands(launches)


if __name__ == "__main__":
    unittest.main()
