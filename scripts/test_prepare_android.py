#!/usr/bin/env python3
"""Smoke-test generated wrapper signing without exposing a real key."""
import subprocess
import sys
import tempfile
from pathlib import Path

script = Path(__file__).resolve().parent / "prepare_android.py"

def run_case(signed: bool):
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        manifest = root / "android/app/src/main/AndroidManifest.xml"
        gradle = root / "android/app/build.gradle.kts"
        manifest.parent.mkdir(parents=True)
        gradle.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text('<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
            '<application android:label="senreader" '
            'android:icon="@mipmap/ic_launcher" /></manifest>',
            encoding="utf-8")
        gradle.write_text("""plugins {
    id("com.android.application")
}
android {
    compileSdk = flutter.compileSdkVersion
    defaultConfig { minSdk = flutter.minSdkVersion }
    compileOptions {}
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}
""", encoding="utf-8")
        if signed:
            (root / "android/key.properties").write_text(
                "storeFile=senreader-upload.jks\nstorePassword=test\n"
                "keyAlias=test\nkeyPassword=test\n",
                encoding="utf-8",
            )
        subprocess.run([sys.executable, str(script)], cwd=root, check=True)
        body = manifest.read_text(encoding="utf-8")
        assert 'android:label="SenReader"' in body
        assert 'android:icon="@mipmap/senreader_launcher"' in body
        assert 'android:roundIcon="@mipmap/senreader_launcher"' in body
        assert body.count('android:label=') == 1
        assert body.count('android:icon=') == 1
        from xml.etree import ElementTree as ET
        ET.fromstring(body)
        resource_dir = manifest.parent / 'res'
        for relative in [
            'mipmap-anydpi/senreader_launcher.xml',
            'mipmap-anydpi-v26/senreader_launcher.xml',
            'drawable/senreader_launcher_foreground.xml',
            'drawable/senreader_launcher_monochrome.xml',
            'values/senreader_launcher_colors.xml',
        ]:
            assert (resource_dir / relative).is_file(), relative
            ET.parse(resource_dir / relative)
        assert 'adaptive-icon' in (
            resource_dir / 'mipmap-anydpi-v26/senreader_launcher.xml'
        ).read_text()
        keep = ET.parse(resource_dir / 'raw/senreader_notification_keep.xml').getroot()
        assert keep.attrib['{http://schemas.android.com/tools}keep'] == '@drawable/senreader_launcher_monochrome'
        result = gradle.read_text(encoding="utf-8")
        assert "compileSdk = 36" in result
        assert "isCoreLibraryDesugaringEnabled = true" in result
        if signed:
            assert result.startswith("import java.util.Properties\n")
            assert "signingConfigs.getByName(\"senreaderStable\")" in result
            assert result.index("plugins {") < result.index("val senreaderSigning")
            assert "storeFile = file(senreaderSigning" in result
        else:
            assert "senreaderStable" not in result
            assert "signingConfigs.getByName(\"debug\")" in result

run_case(False)
run_case(True)
print("Unsigned and stable signing wrapper smoke tests passed")
