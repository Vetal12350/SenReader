#!/usr/bin/env python3
"""Add explicit network permission after `flutter create --platforms android .`."""
from pathlib import Path
manifest = Path('android/app/src/main/AndroidManifest.xml')
if not manifest.exists():
    raise SystemExit('First run: flutter create --project-name senreader --org app.senreader --platforms android .')
body = manifest.read_text(encoding='utf-8')
permission = '<uses-permission android:name="android.permission.INTERNET" />'
if permission not in body:
    body = body.replace('<application', f'    {permission}\n    <application', 1)
    manifest.write_text(body, encoding='utf-8')
print('Android manifest prepared: INTERNET permission present')
