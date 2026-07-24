import os
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VSIX = ROOT / "dist/resume-claude-sessions-bridge-0.1.0.vsix"
INSTALLER = ROOT / "scripts/install-comate-bridge.sh"


class PackageTests(unittest.TestCase):
    def test_vsix_contains_required_files(self):
        subprocess.run(["python3", "scripts/package-comate-bridge.py"], cwd=ROOT, check=True)
        with zipfile.ZipFile(VSIX) as archive:
            names = set(archive.namelist())
        self.assertIn("extension.vsixmanifest", names)
        self.assertIn("[Content_Types].xml", names)
        self.assertIn("extension/package.json", names)
        self.assertIn("extension/extension.js", names)
        self.assertIn("extension/lib/server.js", names)

    def test_vsix_excludes_disallowed_content(self):
        subprocess.run(["python3", "scripts/package-comate-bridge.py"], cwd=ROOT, check=True)
        with zipfile.ZipFile(VSIX) as archive:
            names = set(archive.namelist())
        for name in names:
            self.assertNotIn("test/", name)
            self.assertNotIn(".sock", name)
            self.assertNotIn(".json.meta", name)

    def test_packaging_is_deterministic(self):
        subprocess.run(["python3", "scripts/package-comate-bridge.py"], cwd=ROOT, check=True)
        first_bytes = VSIX.read_bytes()
        subprocess.run(["python3", "scripts/package-comate-bridge.py"], cwd=ROOT, check=True)
        second_bytes = VSIX.read_bytes()
        self.assertEqual(first_bytes, second_bytes)


class InstallerSourceSafetyTests(unittest.TestCase):
    def test_installer_source_is_safe(self):
        source = INSTALLER.read_text()
        for forbidden in ("--reuse-window", " -r ", "reloadWindow", "workbench.action.reloadWindow"):
            self.assertNotIn(forbidden, source)
        self.assertIn("--install-extension", source)
        self.assertIn("--force", source)


def _make_fake_cli(path: Path) -> None:
    path.write_text("#!/usr/bin/env bash\necho \"$@\" > \"$(dirname \"$0\")/invoked-args\"\n")
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class InstallerCliDiscoveryTests(unittest.TestCase):
    """Prove the installer finds a CLI via VSCODE_GIT_ASKPASS_NODE-derived
    remote-cli discovery, without ever invoking a real Comate binary."""

    def _run_probe(self, env_overrides):
        # PROBE_ONLY short-circuits the installer immediately after CLI
        # discovery: it prints the resolved COMATE_CLI path and exits, so
        # the real --install-extension/--force call is never reached.
        env = dict(os.environ)
        env.update(env_overrides)
        env["PROBE_ONLY"] = "1"
        return subprocess.run(
            ["/bin/bash", str(INSTALLER)],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
        )

    def test_prefers_comate_in_remote_cli_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            server_dir = tmp_path / "server"
            remote_cli_dir = server_dir / "bin" / "remote-cli"
            remote_cli_dir.mkdir(parents=True)
            askpass_node = server_dir / "askpass-main.js"
            askpass_node.write_text("// fake")

            _make_fake_cli(remote_cli_dir / "code")
            _make_fake_cli(remote_cli_dir / "comate")

            result = self._run_probe(
                {
                    "VSCODE_GIT_ASKPASS_NODE": str(askpass_node),
                    "PATH": "/usr/bin:/bin",
                }
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(str(remote_cli_dir / "comate"), result.stdout)

    def test_falls_back_to_any_executable_in_remote_cli_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            server_dir = tmp_path / "server"
            remote_cli_dir = server_dir / "bin" / "remote-cli"
            remote_cli_dir.mkdir(parents=True)
            askpass_node = server_dir / "askpass-main.js"
            askpass_node.write_text("// fake")

            _make_fake_cli(remote_cli_dir / "code")

            result = self._run_probe(
                {
                    "VSCODE_GIT_ASKPASS_NODE": str(askpass_node),
                    "PATH": "/usr/bin:/bin",
                }
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(str(remote_cli_dir / "code"), result.stdout)

    def test_falls_back_to_path_when_no_remote_cli_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            _make_fake_cli(bin_dir / "comate")

            result = self._run_probe(
                {
                    "VSCODE_GIT_ASKPASS_NODE": "",
                    "PATH": f"{bin_dir}:/usr/bin:/bin",
                }
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(str(bin_dir / "comate"), result.stdout)

    def test_no_cli_found_reports_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            # Keep /usr/bin:/bin on PATH (needed for python3/dirname/basename
            # used by the installer itself) but supply no comate/code binary
            # anywhere, and no VSCODE_GIT_ASKPASS_NODE-derived remote-cli dir.
            result = self._run_probe(
                {
                    "VSCODE_GIT_ASKPASS_NODE": "",
                    "PATH": f"{tmp}:/usr/bin:/bin",
                }
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("未找到", result.stderr)


if __name__ == "__main__":
    unittest.main()
