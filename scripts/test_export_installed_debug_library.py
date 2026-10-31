#!/usr/bin/env python3
"""Offline checks for the debug-library extraction parser; no device needed."""
import importlib.util
import json
from pathlib import Path
import unittest
from xml.sax.saxutils import escape

file = Path(__file__).with_name("export_installed_debug_library.py")
spec = importlib.util.spec_from_file_location("senreader_debug_backup", file)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ExportTests(unittest.TestCase):
    def test_realistic_flutter_pref_to_non_destructive_backup_schema(self):
        book = {
            "title": "Книга", "entries": {
                "senkuro": {"source": "senkuro", "id": "manga", "title": "Книга"}
            }, "preferredSource": "senkuro", "status": "reading",
            "favorite": True, "lastChapter": "Глава 4",
            "lastPageIndex": 8, "lastPageCount": 19,
            "readChapterKeys": ["senkuro|v1:c3"],
            "seenChapterKeys": ["senkuro|v1:c4"],
        }
        value = escape(json.dumps([book], ensure_ascii=False))
        xml = ('<?xml version="1.0" encoding="utf-8"?>'
               '<map><string name="flutter.senreader.library.v1">'
               + value + '</string></map>').encode("utf-8")
        backup = module.extract_backup(xml)
        self.assertEqual(backup["format"], "senreader.library.backup.v1")
        self.assertEqual(backup["books"], [book])

    def test_missing_and_malformed_library_are_rejected(self):
        with self.assertRaises(ValueError):
            module.extract_backup(b"<map/>")
        with self.assertRaises(ValueError):
            module.extract_backup(b'<map><string name="flutter.senreader.library.v1">null</string></map>')
        with self.assertRaises(Exception):
            module.extract_backup(b"not xml")


if __name__ == "__main__":
    unittest.main()
