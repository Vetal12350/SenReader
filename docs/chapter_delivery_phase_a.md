# Android-only chapter delivery: Phase A

This change builds on PR #115. No server, FCM, signing or application identity changes.

SQLite stores inbox entries with a unique `(profile, canonical chapter identity)`
key. Guest and Firebase UIDs have separate namespaces. Cross-source retries use
one inbox record; hiding never deletes its delivery identity. SQLite serializes
concurrent inserts and hide/restore transactions across Android isolates.

The checker commits inbox entries BEFORE calling the existing library scan-marker
method. Both manual and WorkManager checks therefore have the same delivery path.
If interrupted before inbox commit, no seen marker is written. If interrupted
after commit, replay is safe. Optional OS alerts use a durable at-most-once claim:
a crash after claim can omit the OS alert, but cannot remove the internal entry.
Exactly-once external OS notification delivery cannot be transactional with SQLite.

Legacy global v1 data remains untouched in SharedPreferences. Its entries are
imported once into guest only; authenticated users never inherit them by matching
titles. The original raw preference is retained. Hidden entries remain hidden.
Malformed legacy JSON fails migration without deleting the original.

Scan results capture their profile. A profile switch discards stale discoveries
before publishing or marking another profile's library. No read markers, progress,
selected-source semantics or library status are changed.

Phase B (persistent fair scanning queue, per-provider budgets and UI database
subscriptions) remains separate. Phase A does not authorize source access or
change existing provider limits. Historical seen-without-inbox losses cannot be
reconstructed with certainty from legacy data.

Validation: Flutter tests include guest/two-UID isolation, legacy migration,
concurrent replay/hide, interruption at the inbox/seen boundary and operation
without notification permission. Cloud-local Flutter bootstrap is currently
blocked by unavailable proxy:8080; GitHub Actions must validate Flutter + Android.
