#!/usr/bin/env python3
"""Deterministically package the Comate bridge VS Code extension as a .vsix.

Standard-library only (json, pathlib, zipfile). Produces a reproducible
dist/resume-claude-sessions-bridge-<version>.vsix: fixed member order, fixed
per-entry timestamp, and a fixed static extension.vsixmanifest /
[Content_Types].xml. Only the extension's runtime files are included —
never tests, sockets, metadata files, workspace files, or user settings.
"""
from __future__ import annotations

import json
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE_DIR = ROOT / "comate-bridge"
DIST_DIR = ROOT / "dist"

# Fixed timestamp for every zip entry so repeated builds from the same
# source produce byte-identical archives (deterministic packaging).
FIXED_DATE_TIME = (2020, 1, 1, 0, 0, 0)

CONTENT_TYPES_XML = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\n'
    '  <Default Extension="json" ContentType="application/json" />\n'
    '  <Default Extension="js" ContentType="application/javascript" />\n'
    '  <Default Extension="md" ContentType="text/markdown" />\n'
    '  <Default Extension="vsixmanifest" ContentType="text/xml" />\n'
    '</Types>\n'
)


def build_manifest_xml(name: str, version: str, publisher: str) -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<PackageManifest Version="2.0.0" '
        'xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">\n'
        '  <Metadata>\n'
        f'    <Identity Language="en-US" Id="{name}" Version="{version}" Publisher="{publisher}" />\n'
        f'    <DisplayName>{name}</DisplayName>\n'
        '  </Metadata>\n'
        '  <Installation>\n'
        '    <InstallationTarget Id="Microsoft.VisualStudio.Code" />\n'
        '  </Installation>\n'
        '  <Assets>\n'
        '    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" '
        'Addressable="true" />\n'
        '  </Assets>\n'
        '</PackageManifest>\n'
    )


def load_manifest() -> dict:
    package_json_path = BRIDGE_DIR / "package.json"
    return json.loads(package_json_path.read_text(encoding="utf-8"))


def collect_extension_files() -> list[Path]:
    """Return the fixed allow-list of files to embed under extension/.

    Only package.json, README.md, extension.js, and lib/*.js are included.
    Tests, sockets, metadata, workspace files, and user settings are never
    considered, regardless of what else exists on disk.
    """
    files = [
        BRIDGE_DIR / "package.json",
        BRIDGE_DIR / "README.md",
        BRIDGE_DIR / "extension.js",
    ]
    lib_dir = BRIDGE_DIR / "lib"
    lib_files = sorted(p for p in lib_dir.glob("*.js") if p.is_file())
    files.extend(lib_files)
    missing = [str(p) for p in files if not p.is_file()]
    if missing:
        raise FileNotFoundError(f"required bridge file(s) missing: {', '.join(missing)}")
    return files


def build_vsix(output_path: Path) -> Path:
    manifest = load_manifest()
    name = manifest["name"]
    version = manifest["version"]
    publisher = manifest["publisher"]

    entries: dict[str, bytes] = {
        "extension.vsixmanifest": build_manifest_xml(name, version, publisher).encode("utf-8"),
        "[Content_Types].xml": CONTENT_TYPES_XML.encode("utf-8"),
    }
    for file_path in collect_extension_files():
        relative = file_path.relative_to(BRIDGE_DIR).as_posix()
        entries[f"extension/{relative}"] = file_path.read_bytes()

    DIST_DIR.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        output_path.unlink()

    with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for arcname in sorted(entries):
            info = zipfile.ZipInfo(arcname, date_time=FIXED_DATE_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o644 << 16)
            archive.writestr(info, entries[arcname])

    return output_path


def main() -> int:
    manifest = load_manifest()
    output_path = DIST_DIR / f"{manifest['name']}-{manifest['version']}.vsix"
    build_vsix(output_path)
    print(f"packaged {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
