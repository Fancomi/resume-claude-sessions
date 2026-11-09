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
