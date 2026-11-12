"""Windows setup regression checks with tiny ZIP fixtures and fake downloads."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
POWERSHELL = shutil.which("powershell.exe") if os.name == "nt" else None


def ps_literal(value):
    return "'" + str(value).replace("'", "''") + "'"


@unittest.skipUnless(POWERSHELL, "Windows PowerShell is required")
class WezTermSetupTests(unittest.TestCase):
    def setUp(self):
        self.fixture = ROOT / ".local" / "setup-tests" / uuid.uuid4().hex
        self.fixture.mkdir(parents=True)
        self.cache = self.fixture / "shared-cache"
        self.archive = self.fixture / "package.zip"
        self.directory = "WezTerm-windows-20261108-000000-deadbeef"
        self.make_zip()

    def make_zip(self, escape=False):
        with zipfile.ZipFile(self.archive, "w") as package:
            package.writestr(self.directory + "/wezterm-gui.exe", b"fake GUI; never execute")
            package.writestr(self.directory + "/wezterm.exe", b"fake CLI; never execute")
            if escape:
                package.writestr("../outside.txt", b"must not be extracted")
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def run_ps(self, body, entry=None):
        entry = entry or ROOT / "scripts" / "wezterm.ps1"
        script = (
            "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)\n"
            "$ErrorActionPreference='Stop'\n. " + ps_literal(entry) + "\n" + body
        )
        encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
        return subprocess.run(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
            capture_output=True, encoding="utf-8", timeout=25,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )

    def install_fixture(self):
        return self.run_ps(
            "Install-WezTermArchive -ZipPath " + ps_literal(self.archive)
            + " -ExpectedHash '" + self.digest + "' -HomePath " + ps_literal(self.cache)
            + " -Settings (Get-WezTermSettings)"
        )

    def test_verified_cache_is_reused_by_another_clone_without_network(self):
        installed = self.install_fixture()
        self.assertEqual(installed.returncode, 0, installed.stderr)
        clone = self.fixture / "another clone"
        (clone / "scripts").mkdir(parents=True)
        (clone / "config").mkdir()
        shutil.copyfile(ROOT / "scripts/wezterm.ps1", clone / "scripts/wezterm.ps1")
        shutil.copyfile(ROOT / "config/wezterm.json", clone / "config/wezterm.json")
        result = self.run_ps(
            "function Invoke-WezTermDownload { throw 'Network must not be used' }\n"
            "Install-WezTermPortable -HomePath " + ps_literal(self.cache) + " -Offline",
            entry=clone / "scripts/wezterm.ps1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip().splitlines()[-1], installed.stdout.strip())

    def test_modified_cached_executable_is_rejected(self):
        result = self.install_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        gui = Path(result.stdout.strip())
        gui.write_bytes(b"corrupted")
        result = self.run_ps("Get-CachedWezTerm " + ps_literal(self.cache))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("缓存校验失败", result.stderr)

    def test_session_start_requires_setup_instead_of_downloading(self):
        result = self.run_ps(
            "$env:RESUME_WEZTERM_HOME=" + ps_literal(self.cache) + "\n"
            "function Get-ExistingWezTerm { return $null }\n"
            "function Invoke-WezTermDownload { throw 'Must not download when restoring sessions' }\n"
            "Start-CodexWezTerm -Groups @()"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("配置运行环境.bat", result.stderr)
        self.assertFalse(self.cache.exists())

    def test_check_only_does_not_install_a_cached_archive(self):
        clone = self.fixture / "read-only-check"
        (clone / "scripts").mkdir(parents=True)
        (clone / "config").mkdir()
        shutil.copyfile(ROOT / "scripts/wezterm.ps1", clone / "scripts/wezterm.ps1")
        settings = json.loads((ROOT / "config/wezterm.json").read_text())
        settings["tested"]["sha256"] = self.digest
        (clone / "config/wezterm.json").write_text(json.dumps(settings))
        archives = self.cache / "archives"
        archives.mkdir(parents=True)
        shutil.copyfile(self.archive, archives / (self.digest + ".zip"))
        code = "& " + ps_literal(clone / "scripts/wezterm.ps1")
        code += " -CacheRoot " + ps_literal(self.cache) + " -CheckOnly"
        result = self.run_ps(code)
        self.assertFalse((self.cache / "runtime").exists(), result.stdout + result.stderr)
        self.assertFalse((self.cache / "current.json").exists())

    def test_hash_mismatch_does_not_extract(self):
        result = self.run_ps(
            "Install-WezTermArchive -ZipPath " + ps_literal(self.archive)
            + " -ExpectedHash '" + "0" * 64 + "' -HomePath " + ps_literal(self.cache)
            + " -Settings (Get-WezTermSettings)"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.cache / "runtime").exists())

    def test_archive_cannot_escape_its_destination(self):
        self.make_zip(escape=True)
        result = self.install_fixture()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("越界路径", result.stderr)
        self.assertFalse((self.cache / "runtime").exists())

    def test_proxy_failure_falls_back_and_current_publisher_hash_is_used(self):
        body = r"""
$script:attempts = New-Object 'System.Collections.Generic.List[string]'
function Get-ExistingWezTerm { return $null }
function Get-WezTermDownloadRoutes {
    [pscustomobject]@{Name='failed-proxy';Proxy='http://127.0.0.1:1'}
    [pscustomobject]@{Name='direct';Proxy=''}
}
function Invoke-WezTermDownload {
    param($Url,$Destination,$Route)
    $script:attempts.Add($Route.Name)
    if ($Route.Name -eq 'failed-proxy') { throw 'fixture proxy unavailable' }
    if ($Url.EndsWith('.sha256')) { [IO.File]::WriteAllText($Destination, $script:fixtureHash) }
    else { Copy-Item -LiteralPath $script:fixtureArchive -Destination $Destination }
}
"""
        body += "$script:fixtureHash='" + self.digest + "'\n"
        body += "$script:fixtureArchive=" + ps_literal(self.archive) + "\n"
        body += "$gui=Install-WezTermPortable -HomePath " + ps_literal(self.cache) + "\n"
        body += "ConvertTo-Json @{gui=$gui;attempts=@($script:attempts.ToArray())} -Compress"
        result = self.run_ps(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(record["attempts"], ["failed-proxy", "direct", "direct"])
        self.assertTrue(Path(record["gui"]).is_file())
        marker = json.loads((self.cache / "current.json").read_text())
        self.assertEqual(marker["archive_sha256"], self.digest)

    def test_direct_mode_does_not_probe_local_proxy_or_use_environment_proxy(self):
        result = self.run_ps(
            "$env:HTTPS_PROXY='http://127.0.0.1:1'\n"
            "function Test-ResumeProxyPort { throw 'Must not probe proxy in direct mode' }\n"
            "ConvertTo-Json -InputObject @(Get-WezTermDownloadRoutes -Direct) -Compress"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        routes = json.loads(result.stdout)
        self.assertEqual(len(routes), 1)
        self.assertEqual(routes[0]["Proxy"], "")

    def launch_groups(self, fault="", fail_on=0):
        body = "$env:RESUME_WEZTERM_HOME=" + ps_literal(self.cache) + "\n"
        body += "$script:reportFault=" + ps_literal(fault) + "\n"
        body += f"$script:failOn={fail_on}\n"
        body += r"""
foreach ($name in @('WEZTERM_PANE','WEZTERM_UNIX_SOCKET','WEZTERM_CONFIG_FILE','WT_SESSION','WT_PROFILE_ID')) {
    [Environment]::SetEnvironmentVariable($name, 'stale-parent-value', 'Process')
}
function Get-CachedWezTerm { return 'C:\fake terminal\wezterm-gui.exe' }
$script:launches = New-Object 'System.Collections.Generic.List[object]'
function Start-WezTermGuiProcess {
    param($StartInfo)
    $planPath = $StartInfo.EnvironmentVariables['RESUME_WEZTERM_PLAN']
    $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $inherited = @{}
    foreach ($name in @('WEZTERM_PANE','WEZTERM_UNIX_SOCKET','WEZTERM_CONFIG_FILE','WT_SESSION','WT_PROFILE_ID')) {
        $inherited[$name] = $StartInfo.EnvironmentVariables[$name]
    }
    $script:launches.Add(@{
        file=$StartInfo.FileName; arguments=$StartInfo.Arguments
        shell=$StartInfo.UseShellExecute; plan=$plan; plan_path=$planPath; inherited=$inherited
    })
    $reportedGroups = @($plan.groups | ForEach-Object {
        @{name=$_.name; tab_count=$_.tabs.Count; window_id=0}
    })
    if ($script:reportFault -eq 'name') { $reportedGroups[0].name = 'wrong-group' }
    if ($script:reportFault -eq 'tabs') { $reportedGroups[0].tab_count++ }
    if ($script:reportFault -eq 'windows') { $reportedGroups += $reportedGroups[0] }
    $report = @{ok=$true; groups=@($reportedGroups)}
    if ($script:launches.Count -eq $script:failOn) { $report.ok=$false; $report.error='fixture failure' }
    [IO.File]::WriteAllText($plan.report, (ConvertTo-Json -InputObject $report -Depth 8), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{Id=(1000 + $script:launches.Count); HasExited=$false}
}
$groups = @(
    @{name='1'; tabs=@(
        @{title='one'; cwd="C:\test space's"; args=@('powershell.exe','-NoProfile')},
        @{title='one +CLI'; cwd="C:\test space's"; args=@('powershell.exe','-NoProfile')}
    )},
    @{name='single-two'; tabs=@(
        @{title='two'; cwd='C:\test-two'; args=@('powershell.exe','-NoProfile')}
    )}
)
$failure = $null
try { Start-CodexWezTerm -Groups $groups }
catch { $failure = $_.Exception.Message }
$lastRun = $null
$marker = Join-Path $env:RESUME_WEZTERM_HOME 'last-run.json'
if (Test-Path -LiteralPath $marker) { $lastRun = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json }
ConvertTo-Json -InputObject @{launches=@($script:launches.ToArray()); last_run=$lastRun; failure=$failure} -Depth 12 -Compress
"""
        result = self.run_ps(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_separate_windows_get_independent_processes_and_keep_grouped_tabs(self):
        result = self.launch_groups()
        self.assertIsNone(result["failure"])
        launches = result["launches"]
        self.assertEqual(len(launches), 2)
        self.assertEqual([len(launch["plan"]["groups"]) for launch in launches], [1, 1])
        self.assertEqual([len(launch["plan"]["groups"][0]["tabs"]) for launch in launches], [2, 1])
        self.assertNotEqual(launches[0]["plan_path"], launches[1]["plan_path"])
        self.assertNotEqual(launches[0]["plan"]["report"], launches[1]["plan"]["report"])
        self.assertEqual(launches[0]["plan"]["groups"][0]["tabs"][0]["cwd"], "C:\\test space's")
        for launch in launches:
            self.assertEqual(launch["file"], "C:\\fake terminal\\wezterm-gui.exe")
            self.assertIn("start --always-new-process", launch["arguments"])
            self.assertIn('--config-file "' + str(ROOT / 'config/wezterm.lua') + '"', launch["arguments"])
            self.assertFalse(launch["shell"])
            self.assertTrue(all(value is None for value in launch["inherited"].values()))
        self.assertEqual([window["pid"] for window in result["last_run"]["windows"]], [1001, 1002])
        self.assertEqual([window["group"] for window in result["last_run"]["windows"]], ["1", "single-two"])

    def test_incorrect_startup_reports_are_rejected(self):
        for fault in ("name", "tabs", "windows"):
            with self.subTest(fault=fault):
                self.cache = self.fixture / fault
                result = self.launch_groups(fault=fault)
                self.assertIsNotNone(result["failure"])
                self.assertEqual(len(result["launches"]), 1)
                self.assertIsNone(result["last_run"])

    def test_later_launch_failure_preserves_record_of_first_window(self):
        result = self.launch_groups(fail_on=2)
        self.assertIn("fixture failure", result["failure"])
        self.assertEqual(len(result["launches"]), 2)
        self.assertEqual(len(result["last_run"]["windows"]), 1)
        self.assertEqual(result["last_run"]["windows"][0]["group"], "1")

    def test_setup_entry_and_powershell_scripts_keep_windows_encoding(self):
        paths = [ROOT / "resume-codex-sessions.ps1", ROOT / "scripts/wezterm.ps1"]
        for path in paths:
            data = path.read_bytes()
            self.assertTrue(data.startswith(b"\xef\xbb\xbf"))
            self.assertNotIn(b"\n", data.replace(b"\r\n", b""))
        batch = (ROOT / "配置运行环境.bat").read_text(encoding="utf-8")
        self.assertIn('scripts\\wezterm.ps1', batch)
        self.assertNotIn('127.0.0.1:7890', batch)


if __name__ == "__main__":
    unittest.main()
