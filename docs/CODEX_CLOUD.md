# SenReader — Codex Cloud (no local PC / no local Worker)

This repository is **already on GitHub**. No code migration is required. To run coding tasks entirely on remote OpenAI infrastructure, the owner must **connect GitHub and publish a Codex Cloud environment once**. These account-authorization steps cannot be done on the owner's behalf through a repository commit.

## Create the remote environment (one-time, from web or desktop)

1. Sign into the **same ChatGPT account** that has Codex access. Open Codex on the web (or from ChatGPT). If you see the work-location selector, choose **Work in → Cloud** (labels differ by app language; Ukrainian UI might show `Працювати в → Хмара`).
2. Open **Select environment → Create environment**. An alternative entry point is **Settings → Codex Cloud → Environments → Create environment**.
3. Connect/authorize your GitHub account when prompted and select the **private** `Vetal12350/SenReader` repository. The GitHub connection in an ordinary ChatGPT conversation does not guarantee that the separate Codex environment can use that repository.
4. Let Codex inspect and prepare the project. Ask it to use Flutter **stable** and to execute `bash scripts/codex_cloud_test.sh`. The script installs Flutter in the cloud home folder only if it is absent, then runs package resolution and unit tests. Java and an Android SDK are optional here, because our APK is built using **GitHub Actions**.
5. If network access is restricted, allow just the domains the setup actually needs (such as `github.com`, `pub.dev`, and `storage.googleapis.com`) or enable the appropriate package-manager access. No secrets are required for public source fixtures or Flutter tests.
6. Keep environment privacy **Only me**. Review setup results, **Publish**, and then **Start a new task**. A published environment is needed before cloud tasks can start from mobile.

## Working only from your phone

Open **Codex** in ChatGPT mobile, select the published `SenReader` environment, and start/continue a task. Tasks run in Codex Cloud while the owner's computer is powered off. Return to the **same task** for its uncommitted work; new tasks begin in independent workspaces.

Suggested first prompt (adapt for the actual needed issue):

> Review AGENTS.md and the latest main branch in Vetal12350/SenReader. Work entirely in Codex Cloud, never use my local worker. Implement one small source-backed enhancement from issue #36 that is not already merged. Preserve all existing on-device data, source preference, package ID and signing. Run bash scripts/codex_cloud_test.sh, prepare a focused PR, and rely on GitHub Actions for the APK build. Do not merge or install an APK without reporting test results and data risks.

## Project-specific technical notes

- Flutter/Dart app; package/Android wrapper is generated in CI with:
  `flutter create --project-name senreader --org app.senreader --platforms android .`
- CI then applies `python3 scripts/prepare_android.py`, fetches dependencies, runs `flutter test`, builds Android debug APK, and uploads an Actions artifact.
- Successful `main` builds also upload a direct APK asset to the private [QA release](https://github.com/Vetal12350/SenReader/releases/tag/qa-latest).
- Avoid attempting to push CI build artifacts into the git source tree.
- The debug signing key is ephemeral across CI runs. Installation over another debug-signed build may fail; **do not uninstall existing SenReader before a verified backup**.
- No mandatory login, servers, social features, Shikimori or MyAnimeList.
- `AGENTS.md` supplies data-preservation and workflow guardrails for each coding task.

## If repository is missing in Codex

Check that the environment uses the correct ChatGPT/GitHub identity, that the private repo is selected and authorized for Codex, and that GitHub access has not been restricted to other repositories. Then retry selecting the repository. If Cloud controls are absent, check Codex availability and workspace settings.

Official guide: https://learn.chatgpt.com/docs/environments/cloud-environments
