# Inbox and OS delivery recovery after 6fd74f2

The regression tests first reproduced both remaining P2 issues: reading before
the scanner's insert left an active read entry, and a restart before the OS
handoff never retried the unclaimed notification. The opposite ordering of
reading and insertion already worked.

The scanner now reloads read markers after inserting each chapter, hiding a
matching read entry. If reading completes later, markRead's existing hide sees
the inserted row. Neither operation writes page progress from the worker.
Hidden entries and canonical delivery identities remain stored: replay uses
INSERT OR IGNORE and cannot undo hiding or make duplicate rows. Explicit restore
remains available. Claiming an OS delivery checks hidden state in the same SQLite
transaction as the claim, so hiding before a claim wins over an old snapshot.

SQLite schema v3 adds systemQueuedAt with default zero; inbox rows, read markers,
claims and scan_state are retained. Only newly discovered chapters while system
notifications are opted in get a recoverable queue timestamp. Upgrade/first
opt-in does not enqueue historical rows. Denied permission leaves eligible
pending records untouched. There is no expiry; at most ten claims are processed
per worker pass, using the same profile-bound notification IDs and onlyAlertOnce.
Recovery checks current profile, reading status, source ID and read markers;
it runs even when the scanner reports no new discoveries. A reboot/process restart
does not erase the SQLite queue; Android still determines when work next runs.

External Android delivery and SQLite cannot commit atomically. The existing
at-most-once contract remains explicit: interruption or a plugin failure AFTER
the claim can omit an optional OS alert, but cannot duplicate it on replay or
lose the internal inbox. This change recovers interruption BEFORE the claim.
A hide/read/profile change after the final handoff check may race native display;
it cannot recall an already dispatched Android operation. Real device testing
is required for that boundary. No exactly-once or exact 15-minute guarantee is made.

Validation includes both read/insert orderings, hidden snapshot/replay, concurrent
claims, guest/two UID isolation, profile switch during recovery, permission denial,
bounded recovery, v1/v2 schema upgrades and preservation of reading pages.
Notifications are mocked in Linux; no physical Android/Doze validation was done.

Device acceptance: terminate before/after claim, restart Android, grant/revoke
POST_NOTIFICATIONS, archive/read during a worker pass, switch UIDs, and verify
WorkManager catch-up under Doze/OEM restrictions. Force-stop recovery requires
manual interaction. The PR workflow builds a debug APK; its main-only publishing
job must stay skipped. Signing, application identity and CI are unchanged.
