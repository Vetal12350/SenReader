#!/usr/bin/env python3
"""Idempotently prepare flutter-created Android project for chapter alerts."""
from pathlib import Path
import re
import shutil

manifest = Path('android/app/src/main/AndroidManifest.xml')
gradle = Path('android/app/build.gradle.kts')
if not manifest.exists() or not gradle.exists():
    raise SystemExit('First run flutter create --project-name senreader --org app.senreader --platforms android .')

body = manifest.read_text(encoding='utf-8')
for permission in ('INTERNET', 'POST_NOTIFICATIONS'):
    line = '<uses-permission android:name="android.permission.' + permission + '" />'
    if line not in body:
        body = body.replace('<application', '    ' + line + '\n    <application', 1)

# Use the same, correctly capitalized brand in the Android launcher and Settings.
# Flutter's generated manifest defaults to the lowercase project/package name.
if '<application' not in body:
    raise SystemExit('Expected generated Android application tag')
# Remove prior attributes within the one opening tag before adding our own.
# Replacing them separately using a whole-manifest regex can miss later attrs.
def _brand_application(match):
    tag = match.group(0)
    tag = re.sub(r'\s+android:(?:label|icon|roundIcon)="[^"]*"', '', tag)
    return tag.replace('<application',
        '<application android:label="SenReader" '
        'android:icon="@mipmap/senreader_launcher" '
        'android:roundIcon="@mipmap/senreader_launcher"', 1)

body, branded = re.subn(r'<application\b[^>]*>', _brand_application, body, count=1)
if branded != 1:
    raise SystemExit('Could not brand Android application tag')
manifest.write_text(body, encoding='utf-8')

# Flutter creates the Android wrapper at build time. Copy committed vector
# assets into it on every build, including CI, without external converters.
assets = Path(__file__).resolve().parent.parent / 'branding' / 'android'
res = manifest.parent / 'res'
copies = {
    'senreader_launcher_legacy.xml': 'mipmap-anydpi/senreader_launcher.xml',
    'senreader_launcher_adaptive.xml': 'mipmap-anydpi-v26/senreader_launcher.xml',
    'senreader_launcher_foreground.xml': 'drawable/senreader_launcher_foreground.xml',
    'senreader_launcher_monochrome.xml': 'drawable/senreader_launcher_monochrome.xml',
    'senreader_launcher_colors.xml': 'values/senreader_launcher_colors.xml',
}
for source, destination in copies.items():
    target = res / destination
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(assets / source, target)


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
# Only a securely provided GitHub Actions secret may enable persistent
# signing. Never commit a keystore or credentials to the repository.
if Path('android/key.properties').exists():
    if 'signingConfig = signingConfigs.getByName("debug")' not in build:
        raise SystemExit('Expected Flutter Gradle signing block is missing')
    # Kotlin DSL requires plugins {} before arbitrary top-level statements.
    # Imports are legal before plugins, but val declarations are not.
    build = 'import java.util.Properties\nimport java.io.FileInputStream\n\n' + build
    snippet = """val senreaderSigning = Properties()
val senreaderPropertiesFile = rootProject.file("key.properties")
senreaderSigning.load(FileInputStream(senreaderPropertiesFile))

android {
    signingConfigs {
        create("senreaderStable") {
            keyAlias = senreaderSigning.getProperty("keyAlias")
            keyPassword = senreaderSigning.getProperty("keyPassword")
            storeFile = file(senreaderSigning.getProperty("storeFile"))
            storePassword = senreaderSigning.getProperty("storePassword")
        }
    }
"""
    build = build.replace("android {", snippet, 1)
    build = build.replace('signingConfig = signingConfigs.getByName("debug")',
                          'signingConfig = signingConfigs.getByName("senreaderStable")', 1)
gradle.write_text(build, encoding='utf-8')
# This disposable QA branch must install separately from production SenReader.
# Keep the Kotlin/Flutter MainActivity package, but give Android a unique app ID.
qa_package = 'app.senreader.senreader.scrollqa20261102'
original_id = 'applicationId = "app.senreader.senreader"'
qa_gradle = gradle.read_text(encoding='utf-8')
if original_id in qa_gradle:
    gradle.write_text(qa_gradle.replace(
        original_id, f'applicationId = "{qa_package}"', 1),
        encoding='utf-8')
    qa_manifest = manifest.read_text(encoding='utf-8')
    activity = 'android:name=".MainActivity"'
    label = 'android:label="SenReader"'
    if activity not in qa_manifest or label not in qa_manifest:
        raise SystemExit('Expected generated Flutter activity and label not found')
    qa_manifest = qa_manifest.replace(
        activity, 'android:name="app.senreader.senreader.MainActivity"', 1)
    qa_manifest = qa_manifest.replace(
        label, 'android:label="SenReader Scroll QA"', 1)
    manifest.write_text(qa_manifest, encoding='utf-8')
elif 'applicationId =' in qa_gradle:
    raise SystemExit('Unexpected generated Android application ID for QA')

print('Android manifest and Gradle prepared for networking and notifications')
