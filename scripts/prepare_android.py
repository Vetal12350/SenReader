#!/usr/bin/env python3
"""Idempotently prepare flutter-created Android project for chapter alerts."""
from pathlib import Path

manifest = Path('android/app/src/main/AndroidManifest.xml')
gradle = Path('android/app/build.gradle.kts')
if not manifest.exists() or not gradle.exists():
    raise SystemExit('First run flutter create --project-name senreader --org app.senreader --platforms android .')

body = manifest.read_text(encoding='utf-8')
for permission in ('INTERNET', 'POST_NOTIFICATIONS'):
    line = '<uses-permission android:name="android.permission.' + permission + '" />'
    if line not in body:
        body = body.replace('<application', '    ' + line + '\n    <application', 1)
manifest.write_text(body, encoding='utf-8')

# flutter_local_notifications 22 requires Java API desugaring even for
# immediate notifications. This applies only to the generated debug/release
# Android wrapper and does not require committing SDK-generated files.
build = gradle.read_text(encoding='utf-8')
# Current Android notification plugin requires API 36 to compile, API 24 minimum.
build = build.replace('compileSdk = flutter.compileSdkVersion', 'compileSdk = 36', 1)
build = build.replace('minSdk = flutter.minSdkVersion', 'minSdk = 24', 1)
if 'isCoreLibraryDesugaringEnabled = true' not in build:
    if 'compileOptions {' not in build:
        raise SystemExit('Generated Android Gradle format changed; review desugaring setup')
    build = build.replace('compileOptions {',
                          'compileOptions {\n        isCoreLibraryDesugaringEnabled = true', 1)
if 'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:' not in build:
    build += '\n\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
gradle.write_text(build, encoding='utf-8')

# Disposable QA package has a unique Android ID, so older app data stays intact.
qa_id = 'app.senreader.senreader.zazazaqa2'
build = gradle.read_text(encoding='utf-8')
old_id = 'applicationId = "app.senreader.senreader"'
if old_id not in build:
    raise SystemExit('Expected generated Android application ID not found')
gradle.write_text(build.replace(old_id, f'applicationId = "{qa_id}"', 1),
                  encoding='utf-8')
body = manifest.read_text(encoding='utf-8')
if 'android:name=".MainActivity"' not in body:
    raise SystemExit('Expected generated Flutter activity not found')
body = body.replace('android:name=".MainActivity"',
                    'android:name="app.senreader.senreader.MainActivity"', 1)
body = body.replace('android:label="senreader"',
                    'android:label="SenReader ZazaZa QA"')
manifest.write_text(body, encoding='utf-8')

print('Android manifest and Gradle prepared for networking and notifications')
