#!/usr/bin/env python3
"""Read local Codex rollout metadata without changing any session files."""

import argparse
import json
import os
from pathlib import Path
import re
import sys
import uuid


SESSION_ID_SUFFIX = re.compile(r"([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$")


def is_subagent(source):
    if isinstance(source, str):
        return source.lower().replace("_", "").startswith("subagent")
    if isinstance(source, dict):
        return any(str(key).lower().replace("_", "") == "subagent" for key in source)
    return False


def read_session(path, include_subagents=False):
    try:
        with path.open(encoding="utf-8-sig", errors="replace") as stream:
            # Metadata is at the start; never scan a whole conversation looking for it.
            for line_number, line in enumerate(stream):
                if line_number >= 64:
                    break
                try:
                    record = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if not isinstance(record, dict) or record.get("type") != "session_meta":
                    continue
                meta = record.get("payload")
                if not isinstance(meta, dict):
                    continue
                if not include_subagents and any(
                    is_subagent(meta.get(key)) for key in ("source", "thread_source")
                ):
                    return None
                session_id = meta.get("id") or meta.get("session_id")
                if not session_id:
                    match = SESSION_ID_SUFFIX.search(path.stem)
                    session_id = match.group(1) if match else ""
                session_id = str(uuid.UUID(str(session_id)))
                cwd = meta.get("cwd")
                if not isinstance(cwd, str) or not Path(cwd).is_absolute() or not Path(cwd).is_dir():
                    return None
                return {
                    "id": session_id,
                    "cwd": cwd,
                    "name": Path(cwd).name or cwd,
                    "last_seen": path.stat().st_mtime,
                }
    except (OSError, ValueError):
        # A deleted, unreadable, malformed, or incomplete rollout must not hide the others.
        return None
    return None


def discover_sessions(root, include_subagents=False):
    sessions = {}
    for path in Path(root).rglob("*.jsonl"):
        session = read_session(path, include_subagents)
        if session is None:
            continue
        previous = sessions.get(session["id"])
        if previous is None or session["last_seen"] > previous["last_seen"]:
            sessions[session["id"]] = session
    return sorted(sessions.values(), key=lambda s: (-s["last_seen"], s["id"]))


def main():
    default_home = os.environ.get("RESUME_CODEX_HOME") or os.environ.get("CODEX_HOME") or str(Path.home() / ".codex")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(default_home) / "sessions")
    parser.add_argument("--include-subagents", action="store_true")
    parser.add_argument("--format", choices=("json", "nul"), default="json")
    args = parser.parse_args()
    if not args.root.is_dir():
        parser.error("Sessions directory not found: %s" % args.root)
    sessions = discover_sessions(args.root, args.include_subagents)
    if args.format == "nul":
        for session in sessions:
            fields = (str(int(session["last_seen"])), session["id"], session["cwd"])
            sys.stdout.buffer.write(("\0".join(fields) + "\0").encode("utf-8"))
    else:
        # ensure_ascii also works in Windows consoles with a legacy code page.
        print(json.dumps(sessions, ensure_ascii=True, indent=2))


if __name__ == "__main__":
    main()
