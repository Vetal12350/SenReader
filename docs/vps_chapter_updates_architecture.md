# SenReader: multi-user VPS chapter-update architecture (proposal)

Status: **design only, not deployed**. No source polling or scraping is authorized by this document.

## User goal and boundaries

* All books explicitly placed in `Читаю` are equal. No automatic activity tiers.
* Discover chapter updates when the app is closed, whenever a legally permitted upstream feed or API is available.
* Show already-synced chapters immediately in the **in-app inbox**. Android OS notifications are optional and disabled by default.
* Support owner and invited friends on the same VPS without exposing libraries, history, login credentials, or inbox items to one another.
* Existing reading progress and local data remain authoritative. Never change read marks, active translation or preferred source as a consequence of background updates.
* Never fetch or proxy manga images/pages on the VPS. Server stores only approved chapter metadata.

## Explicit permission gates

1. **Senkuro:** https://senkuro.com/terms explicitly prohibits automated access via bots/parsers/crawlers without prior approval and disallows bulk requests / bypass of limits. A public-facing GraphQL endpoint does not itself grant permission. **No VPS connector for Senkuro until written approval or a clearly licensed developer feed/API with applicable limits.**
2. **ReadManga:** https://readmanga.me/page/user_agreement forbids use via third-party programs, parsers and mobile apps. **No VPS connector without written exception / approved integration.**
3. No circumvention of robots/anti-bot challenges, CAPTCHA, IP limits, rate limits, login restrictions or paywalls. On 403/429, stop/back off; do not rotate IP/accounts.
4. User's voluntary cloud-update opt-in is required before any reading-list subscription is exported to VPS, including by friends. An Android OS notification permission is **not** required for the in-app inbox (only for OS notifications on supported Android versions).
5. If permission isn't obtained, the cloud service runs only with explicitly authorized upstream feeds; sources without approved feeds remain **local-only**, with clear per-source status shown to the user. Do not pretend the VPS is checking them.
6. Re-evaluate terms before any provider becomes active. Store the provenance and granted scope (read-only chapter metadata, permitted frequency, duration, user count, and revocation conditions).

## Existing components

* Firebase Authentication via `lib/data/firebase_account_service.dart`, verified-account gating.
* Per-UID library in Firestore `users/{uid}/library/{bookId}`, with owner-only security rules in `firestore.rules`.
* `lib/data/chapter_inbox_store.dart` stores the device's local, persistent, read/unread state.
* `lib/data/chapter_checker.dart` and `chapter_background_scheduler.dart` are existing local-only mechanisms and remain a fallback. Currently background checking and system notification permission are improperly coupled; separate these in the client rollout.

## Proposed server design

```text
SenReader (signed-in, opt-in)
  -> only source key, source's manga ID, preferred source, title key
  -> Firebase / VPS subscription API [Firebase Auth ID token validated]
  -> per-user subscriptions (private; can opt out/delete)
                               |
                               v
                deduplicated source/manga-key catalog
                               |
                     approved metadata provider
                               |
                shared release cache with timestamps
                               |
                               v
           per-UID release/inbox fan-out or delta cursor
                               |
                               v
SenReader starts -> show cached local inbox instantly -> fetch cloud deltas
                -> validate subscription, dedup chapter identities
                -> persist entries in existing ChapterInboxStore
                -> refresh UI, no OS notification necessary
```

* **Identity & isolation:** Verify Firebase ID tokens, derive the UID from the verified token on the server (never trust client-supplied UID). Apply owner-only security rules for `subscriptions` and `inbox`. Google/email accounts are already supported; guest mode keeps local-only updates. Do not expose another user's subscription counts/IDs or library titles.
* **Data minimization:** Server stores `uid`, source identifier, provider's manga ID, optional normalized title key, last delivered release cursor and unsubscribe state. Do **not** export `readChapterKeys`, last-read chapter/page, viewing history, book ratings, full `SavedBook.toJson()`, passwords, email addresses or Google refresh tokens.
* **Shared source cache:** Uniqueness key `(source, sourceMangaId)`; checked only once per approved provider schedule even if many users subscribe. Do not confuse equal title names across different provider IDs. Verify chapter identity/availability with authorized metadata, don't fetch chapter images.
* **Per-user delivery:** Maintain per-UID cursors and release IDs; on opt-in set an initial baseline so historical back catalog never floods the inbox. Every feed event must be matched to the user's current subscription and is deduplicated across reconnects/restarts.
* **Offline and sync:** Read local inbox first, then merge verified events from cloud using stable `source + chapter identity`; removing a title/opt-out stops new events; preserve local history on server outage. On switching Google accounts, cancel old subscriptions and clear pending old-user UI events, without deleting per-account data.
* **Schedules:** Provider-approved cadence and concurrency only. Keep track of oldest successful/attempted check, provider-specific timeout/backoff, per-source failure/429 metrics, and next retry. Resume safely after VPS restart. No promise of exact-minute updates.
* **Storage:** For first iteration, reuse Firestore's existing owner-scoped database for user records; a small process on the existing VPS can maintain permitted shared source cache using a separate database (SQLite with WAL / Postgres). Never embed Firebase Admin service-account keys in APK/GitHub repo. Use least-privilege backend credentials and firewall/TLS.
* **Security:** Opt-in toggle and transparent privacy message, unsubscribe and deletion, no cross-user data in logs, redacted monitoring, bounded retention of release metadata, backup and credential rotation. For any user-specific Firestore docs expose only the owning UID in rules and test cross-user denial with Firebase emulator.
* **Device permissions:** `INTERNET` (already used for Firebase) suffices for in-app updates. `POST_NOTIFICATIONS` is separate and never gates syncing.
* **Diagnostics:** `last successful source check`, `last server synchronization`, `updates fetched`, `provider not enabled (permission pending)`, `error / delayed`; never label server check success if no approved source was contacted.

## Delivery phases

1. **Permission and product boundary:** Request written permission/approved metadata endpoint from upstream. Design privacy/opt-in screen, keep existing local code operational.
2. **Multi-user backend with mock/authorized feed:** Implement secure UID-scoped subscriptions, shared metadata catalog, per-user deltas and tests, **no real Senkuro/ReadManga network calls**.
3. **Client integration:** Add cloud update opt-in, opt-out, local-inbox merge-on-open, source-status diagnostics, OS notifications as a separate optional feature. Regression for different users, revoked tokens, account switch, in-app read/hide persistence, guest fallback.
4. **Permitted provider(s) only:** Implement a connector if the upstream grants relevant scope; respect rate limits and add operational alerts. Do not enable a connector merely because code is available.
5. **Deployment to current VPS:** Only after explicit host access, credentials and maintenance constraints. Deploy separate non-root service, tests, health checks and backups. Never disclose service keys in chat or commits.

## Acceptance criteria

* Two friends signed into distinct Google/email Firebase accounts see **only** their own chapters and neither can read the other's subscriptions/inbox.
* One authorized upstream manga followed by 10 users costs **one provider check per period**, not 10.
* App shows previously synced updates immediately when launched, and reconciles new ones after network connects; all unread/hidden state stays intact.
* Disabling Android notifications leaves in-app updates fully functional.
* Revoking cloud opt-in stops sending library subscriptions and eliminates server-side personal records according to the defined deletion policy.
* Disallowed/unapproved providers perform **zero** VPS network requests.
* Existing signed APK, progress, favorites and local chapter checking remain unchanged until a separately tested and accepted client release.
