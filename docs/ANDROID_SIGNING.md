# SenReader: safe Android updates and signing

## Why a downloaded APK might refuse to update the installed app

Android requires the **same package name and the same signing certificate** for
an in-place update. This repository previously built debug APKs on temporary
GitHub runners; each runner normally generates a fresh debug certificate.
A new runner cannot recover the signing key from an earlier runner's APK.

**A new stable key cannot update those earlier debug builds in place.**
Do not uninstall an app containing bookmarks, reading history or favorites
until you have a verified backup and a migration plan. Merely turning on stable
signing does not recover an old debug key or preserve Android app storage.

## Stable release signing setup (repo owner only, once)

1. Generate an Android upload keystore on a trusted, private machine or
   private cloud workspace with a trusted JDK:
   `keytool -genkeypair -v -keystore senreader-upload.jks -alias senreader -keyalg RSA -keysize 3072 -validity 10000`
   Choose strong unique keystore and key passwords.
2. **Back up the .jks and passwords offline**. Losing them prevents subsequent
   signed updates. Never paste them into a chat, GitHub issue, pull request,
   code or APK artifact.
3. In GitHub repository **Settings → Secrets and variables → Actions**,
   create these four *repository secrets*:
   - `SENREADER_SIGNING_KEY_BASE64` — base64 of the entire binary JKS
     (for example `base64 -w0 senreader-upload.jks` on Linux).
   - `SENREADER_SIGNING_STORE_PASSWORD` — keystore password.
   - `SENREADER_SIGNING_ALIAS` — `senreader` (or your chosen alias).
   - `SENREADER_SIGNING_KEY_PASSWORD` — private key password.
4. The `main` GitHub Actions workflow will build and publish a persistently
   signed **release** APK at:
   `https://github.com/Vetal12350/SenReader/releases/download/qa-latest/SenReader-latest.apk`
   Confirm its release notes contain `Подписанная постоянным ключом`.
5. Subsequent signed release updates with the **same** key, package ID and
   appropriate version code can install without uninstalling. GitHub pull
   requests never receive these secrets; they build debug APKs only.

The existing `SenReader-latest-debug.apk` URL deliberately remains a debug
build for CI verification. **Do not use it for routine user upgrades.**

## Migration from an earlier debug installation

Because earlier debug keys are not retained, Android will reject changing
that installation to the new release key. First back up user data via a
verified export function on the *currently installed* app. Existing
`LibraryStore` has JSON serialization / transfer support internally, but
do not assume a visible working export/import flow is present yet.
Avoid uninstalling without verified restoration of chapters, bookmarks,
sources, favorites, settings and read history.

The user may need to migrate once to the stable release. After that, release
builds can be updated normally. This documentation does not promise migration
from a build whose signing key is lost.
