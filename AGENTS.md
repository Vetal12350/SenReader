# SenReader — instructions for Codex Cloud and other coding agents

## Project and owner requirements
- This is a **personal, private, local-first Android manga/manhwa reader**, not a social platform.
- Tech: Flutter/Dart; Android APK is built and tested in GitHub Actions.
- Public sources currently supported: Senkuro and ReadManga. ReManga was removed; keep historical bookmarks/backup entries intact and offer explicit source replacement. Preserve strict separation of source adapters.
- **Do not** add community profiles, social activity, comments, friends, Shikimori or MyAnimeList integration. Do not introduce a server or account requirement without an explicit new user request.
- User-visible interface language: Russian. Development discussion may be in Russian.
- The local Codex Control Center Worker is intentionally not required. **Never add the `codex-local` label or require an always-on PC** for Cloud tasks.

## Data safety — highest priority
- Never delete or reset existing on-device bookmarks, read chapter markers, last chapter/page, active source, notification preferences, or theme settings.
- Keep Android application ID/package name stable.
- GitHub Actions debug APK signing is **not stable across builds**; a new APK may not install over the old one. Do not tell the user to uninstall the installed app until an independently verified backup/migration is available.
- Treat library import/export as potentially destructive: preview, deduplicate conservatively, explicit confirmation and test round-trips. Current JSON transfer core exists but the UI may not be implemented.
- Do not commit secrets, signing certificates, API tokens, user accounts, bookmarks or downloaded manga media.

## Architecture and product behavior
- Preserve **one user-selected active source per saved title**. Do not silently change it on network errors. Inaccessible, paid or protected material remains inaccessible; do not bypass auth, CAPTCHA, DRM or payment restrictions.
- Reading progress and `read` markers are different. Scrolling or opening an image must not mark a chapter as completed automatically without the agreed behavior.
- Preserve local-first functionality without sign-in or a backend.
- Never manufacture author/character/related-title metadata, ratings, popularity charts, chapter lists or unavailable content. Only display source-backed data.
- Prefer small, scoped changes with regression tests rather than broad UI rewrites.

## Standard Cloud development workflow
1. Read this file, the relevant `docs/` material, and inspect current `main` before editing. Avoid relying on old README claims when the code has changed.
2. Work on a separate feature branch. Do **not** commit directly to `main`; do not add the local worker label.
3. For development in an initialized Codex Cloud environment, run `bash scripts/codex_cloud_test.sh` (installs Flutter stable if needed, runs `flutter pub get` and `flutter test`). Flutter/Android SDK are **not** required on the user's PC.
4. The canonical end-to-end Android check is `.github/workflows/android-apk.yml`: GitHub Actions builds the APK after tests, no local machine involved.
5. Open a pull request; report test evidence, known limitations, and data-migration risks. Only merge after successful CI and review/approval in the current task.
6. `main` CI publishes a private direct APK to the `qa-latest` GitHub Release after success. Do not pretend the URL is public; the owner must be signed in to GitHub.
7. After a change, keep README/docs consistent and avoid changing the Android signing/package identity inadvertently.

## Important files and backlog
- UI shell / catalog: `lib/main.dart`
- Reader / continuous chapters: `lib/ui/reader_page.dart`
- Title details: `lib/ui/detail_page.dart`
- Local persistence and read state: `lib/data/library_store.dart`
- Reader/source models: `lib/core/models.dart`
- Source adapters: `lib/data/` and `lib/core/`
- CI: `.github/workflows/android-apk.yml`
- Open work scope: GitHub issues #36 (catalog, reading, source-backed title details) and #37 (local theme, backup/import UI, *optional* private sync). Verify what has already been merged before starting any issue.
- Cloud onboarding: `docs/CODEX_CLOUD.md`

Do not claim a feature is available until code and relevant tests actually demonstrate it.
