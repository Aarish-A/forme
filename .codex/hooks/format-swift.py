#!/usr/bin/env python3
"""Format existing Swift files named by a successful Codex patch hook."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


def main():
    event = json.load(sys.stdin)
    root = Path(__file__).resolve().parents[2]
    cwd = Path(event.get("cwd") or root).resolve()
    tool_input = event.get("tool_input") or {}
    response = event.get("tool_response") or {}
    if isinstance(response, dict) and response.get("isError"):
        return
    names = []
    if isinstance(tool_input, dict):
        path = tool_input.get("file_path")
        if isinstance(path, str):
            names.append(path)
        patch = tool_input.get("command", "")
        if isinstance(patch, str):
            names.extend(re.findall(
                r"^\*\*\* (?:Add File|Update File|Move to): (.+)$",
                patch, re.MULTILINE,
            ))
    if isinstance(response, dict) and isinstance(response.get("filePath"), str):
        names.append(response["filePath"])
    files = set()
    for name in names:
        path = (cwd / name).resolve()
        if root in path.parents and path.suffix == ".swift" and path.is_file():
            files.add(str(path))
    if not files:
        return
    formatter = shutil.which("swiftformat")
    if not formatter:
        raise RuntimeError("SwiftFormat is missing; install the version in .tool-versions")
    pinned = next(line.split()[1] for line in
                  (root / ".tool-versions").read_text().splitlines()
                  if line.startswith("swiftformat "))
    actual = subprocess.check_output([formatter, "--version"], text=True).strip()
    if actual != pinned:
        raise RuntimeError("SwiftFormat version differs from .tool-versions; run make tools")
    subprocess.run([formatter, "--quiet", "--config", str(root / ".swiftformat"),
                    *sorted(files)], cwd=root, check=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Formatting failure is feedback, not a reason to hide the completed edit.
        print(json.dumps({"systemMessage": "Swift formatting hook: " + str(error)}))
