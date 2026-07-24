import subprocess
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


if __name__ == "__main__":
    unittest.main()
