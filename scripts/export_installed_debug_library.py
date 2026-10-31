#!/usr/bin/env python3
"""Export only SenReader's library from an installed debuggable Android APK.

Runs on the owner's trusted computer, with Android platform-tools (adb).
Never uploads the library or prints any of its contents.
"""
import argparse
import json
import os
import subprocess
from pathlib import Path
from xml.etree import ElementTree

KEY = "senreader.library.v1"
FORMAT = "senreader.library.backup.v1"
DEFAULT_PACKAGE = "app.senreader.senreader"


def extract_backup(xml_bytes: bytes) -> dict:
    if len(xml_bytes) > 8_000_000:
        raise ValueError("App preferences unexpectedly large")
    root = ElementTree.fromstring(xml_bytes)
    for entry in root.findall("string"):
        if entry.get("name") in ("flutter." + KEY, KEY):
            books = json.loads(entry.text or "")
            if not isinstance(books, list):
                raise ValueError("Library value is not a list")
            if len(books) > 10000:
                raise ValueError("Unreasonable library size")
            if not all(isinstance(book, dict) for book in books):
                raise ValueError("Invalid library entry")
            return {"format": FORMAT, "books": books}
    raise ValueError("No SenReader library found in Android preferences")


def read_debug_preferences(package: str) -> bytes:
    if not package or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._" for char in package):
        raise ValueError("Invalid Android package name")
    # run-as works only on installed *debuggable* APKs. No root needed.
    command = ["adb", "exec-out", "run-as", package, "cat",
               "shared_prefs/FlutterSharedPreferences.xml"]
    result = subprocess.run(command, capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError(
            "ADB cannot access the debuggable application storage. "
            "Confirm USB debugging, device authorization, package name, "
            "and that the installed app is a debug build.")
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", default=DEFAULT_PACKAGE)
    parser.add_argument("--output", default="senreader-library-backup.json")
    args = parser.parse_args()
    output = Path(args.output)
    if output.exists():
        parser.error("Destination already exists; choose a new output path (will not overwrite).")
    try:
        backup = extract_backup(read_debug_preferences(args.package))
        raw = json.dumps(backup, ensure_ascii=False, separators=(",", ":"))
        if len(raw.encode("utf-8")) > 2_000_000:
            raise ValueError("Backup too large for the current app importer")
        previous_umask = os.umask(0o077)
        try:
            with output.open("x", encoding="utf-8") as file:
                file.write(raw)
                file.write("\n")
        finally:
            os.umask(previous_umask)
    except (OSError, ValueError, RuntimeError, ElementTree.ParseError, json.JSONDecodeError) as err:
        parser.error(str(err))
    print(f"Saved {len(backup['books'])} title(s) to {output}. "
          "Keep this file private; verify it before removing the old app.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
