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
4. A push to `main` or a manual **Run workflow** on `main` will build and publish a persistently
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
that installation to the new release key. First back up user data from the *currently installed* APK. Once the
backup UI is installed, open **Настройки → Резервная копия библиотеки →
Копировать библиотеку** and paste the JSON into a separate private note/file.
Do not rely on clipboard retention across uninstall. After a fresh install,
copy that saved JSON and use **Настройки → Импорт из буфера**; confirm the
preview, verify titles, read markers and favorites before deleting the backup.
Existing local titles are skipped rather than overwritten. If the currently
installed APK cannot show these backup controls and cannot be upgraded to the
backup-enabled build, this procedure alone cannot extract its private data.
Avoid uninstalling without verified restoration of chapters, bookmarks,
sources, favorites, settings and read history.

The user may need to migrate once to the stable release. After that, release
builds can be updated normally. This documentation does not promise migration
from a build whose signing key is lost.


## Fallback for an already installed APK with a lost debug certificate

When Android refuses to install the backup-enabled debug APK over the current
one, a *debuggable* previous APK can still export its private library via ADB
on a trusted PC. This is an alternative **before uninstalling**, not a
requirement for future signed updates.

1. Keep the existing SenReader installed. Enable USB debugging, authorize your
   own computer and install Android Platform Tools (adb) and Python 3.
2. In this repo, run:
   `python3 scripts/export_installed_debug_library.py --output senreader-library-backup.json`
3. The script uses `adb exec-out run-as app.senreader.senreader` to read only
   the local library preference. It does not need root, does not use a server,
   does not upload the backup and refuses to overwrite an existing backup.
4. Verify the saved file exists and safely keep a private copy. The JSON can
   be transferred back to the phone and copied into the clipboard for the
   Settings import UI of the new signed build (PR #62 and later).
5. Verify the restored library on the new installation, including read markers
   and source preferences. Reenable notification permissions and choose theme.

**Limitations:** `run-as` works only if the original installed APK is
*debuggable* and ADB authorization succeeds. Non-debuggable releases are
inaccessible by this method without an existing app export. Do not attempt
uninstall/reinstall if the backup extraction failed. No private data is sent to
ChatGPT or GitHub Actions; keep the local JSON out of commits and messages.


## Windows one-time setup (trusted local shell, never inside Codex Worker)

The universal Codex Worker creates PRs from GitHub issues and its coding
subprocess is NOT a secure credential broker. Do not give it the keystore,
passwords, signing secrets, or authority to rotate a signing identity.

On your own Windows PC, **stop the worker before creating or handling
credentials**. Install GitHub CLI, JDK 17+ (keytool) and authenticate with
\`gh auth login\` as the repository owner.

From a trusted clone of SenReader, check only public secret names:

\`\`\`powershell
powershell -NoProfile -File .\scripts\setup_stable_signing.ps1 -CheckOnly
\`\`\`

If **none** of the four secrets exist, choose an offline-backed-up private
folder outside any Git checkout and cloud-synced folder. Create that folder
first, then run:

\`\`\`powershell
powershell -NoProfile -File .\scripts\setup_stable_signing.ps1 -Configure -KeystorePath "D:\PrivateKeys\SenReader\senreader-upload.p12"
\`\`\`

The script prompts for key generation and passwords locally. It sends encrypted
secret values using GitHub CLI standard input; it neither prints nor commits
secrets. It refuses to replace any existing GitHub signing secrets, to avoid
accidental certificate rotation. A **partial** upload requires owner review
before retry; do not overwrite an active release key.

After setting all four secrets, trigger an ordinary **main** Build Android APK
workflow and inspect the successful release run and published
\`SenReader-latest.apk\`. The listing of four names alone does NOT prove a
valid signature, nor that an already-installed debug APK can update in place.
The first switch from a different debug certificate still needs a verified
library export and one-time migration. Never uninstall before backup.
