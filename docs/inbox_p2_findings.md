# Focused P2 follow-up on main 6fd74f2 (#119/#123 retained)

## Inbox/user-action race
SQLite inserts use IGNORE and hide/restore update inside a transaction, scoped by
profile. Concurrent insert/hide and cross-source replay cannot overwrite hidden
state or insert another canonical identity. Existing scan-state/library isolation
is untouched. Regression tests retain stale snapshots and verify database state.

A separate UI defect was reproduced: polling captures a visible entry; user hides
it while the query is pending; the user-triggered refresh is dropped by the busy
guard; old query then paints the entry visible again. A local revision and queued
refresh discard that snapshot and fetch the current state. The store is captured
before awaiting a user action, preserving account scope.

## Pending optional OS notifications
Previously claimSystemNotification permanently marked delivery before Android.show;
platform failure or death in that window consumed the alert. Also an empty scanner
report never drained persisted pending items. The regression commit precedes fixes.

A v3 additive SQLite migration retains inbox, scan_state and old systemClaimed
values; it adds only systemLease/systemToken. New delivery acquires a finite lease,
checks current subscription/UID, uses the existing stable profile/title/chapter ID,
then acknowledges OS success. Exceptions release the lease; process death permits
retry after expiry. A restarted worker drains pending visible inbox entries even
with no new discoveries. No permission means no claim, no show, inbox still works.

Existing active Android IDs are acknowledged without showing again. Stable IDs and
onlyAlertOnce avoid duplicate active notifications and repeated alerting on replace.
SQLite and Android NotificationManager cannot commit atomically: if the OS accepted
an alert, the process died before acknowledgement, and the alert was then dismissed
or cleared by reboot, a retry may show it again. Strict exactly-once across that
boundary is impossible without an OS receipt; tests model these boundaries but do
not claim real device/Doze validation. Legacy systemClaimed=1 is preserved: it is
impossible to distinguish old successful and lost deliveries safely.

Hardware acceptance: kill before/after show, restart/reboot with active/dismissed
alerts, concurrent isolates, permission revocation, account switch, UI hide/restore
while polling. No signing/applicationId, CI, reader progress or source-limit changes.

## Review follow-up: explicit OS intent and read reconciliation

Schema v4 adds systemQueuedAt=0 for historical v1/v2 and lease-only v3 rows.
Only a newly inserted release discovered while OS notifications are opted in is
queued. INSERT IGNORE never turns a pre-opt-in/archived/delivered row into new OS
work. Permission denial preserves queued intent; it does not opt historical rows
in. sourceId is saved with new records to reject replaced source links.

The worker/manual checker capture OS opt-in, insert intent with the inbox record,
then re-read read markers and hide the chapter if reading completed before insert.
If reading wins later, markRead's existing hide sees the row. This narrow change
is ported from #124; its competing claim-before-show implementation is not used.

Pending OS selection is indexed SQL, bounded to ten rows per pass, excluding sent,
unqueued and leased rows. Hidden/invalid entries are dequeued without changing the
visible archive. The library is decoded once per batch; a cheap profile/raw-library
snapshot check invalidates the batch on concurrent read/source/status changes.
Lease, fencing, active-ID acknowledgement and crash retry from #125 are retained.

Historical lease-only v3 rows without recorded intent cannot safely be recovered
as OS alerts: they remain in the internal inbox. Both draft v3 table shapes are
accepted by additive column detection; no parallel v3 migration is merged.
