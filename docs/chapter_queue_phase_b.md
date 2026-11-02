# Phase B: Android-local resumable chapter checks

Based on phase A branch (PR #117). No servers, FCM or paid infrastructure.

A SQLite job is keyed by profile, saved book, provider and manga ID. Reconcile
retains existing state and removes subscriptions no longer eligible. Only reading
and trusted linked sources qualify. A claim persists a finite five-minute lease,
incrementing fencing token and turn before network I/O. Finishing checkpoints each
pair. A killed worker leaves a lease which expires: no task is permanently lost.
There is no library-position or reading-activity priority. Providers alternate.

Scheduled work uses a 120-second soft budget instead of a 12-source cap. The active
pair is bounded by the remaining duration. No new production HTTP work or inbox
commit starts after the deadline. A timeout retains the finite lease; subsequent
runs continue other eligible jobs. A delayed HTTP response may still finish in the
transport; the deadline prevents further chained requests or inbox writes.

Production HTTP calls use a persistent device-wide per-provider gate: one request
at a time, a two-second minimum interval, and an expiring request lease. Injected
fixture clients keep their existing deterministic transport. HTTP 429 persists
Retry-After (at least one minute; default 30 minutes); HTTP 403 defers 24 hours.
One provider's cooldown does not block the other queue. These conservative defaults
are not a declaration of permission or a guarantee that 429 cannot occur. Existing
upstream access rules remain applicable; no anti-bot or CAPTCHA bypass is added.

WorkManager's existing connected/battery constraints and 15-minute opportunistic
schedule remain. Catch-up is unawaited by UI startup and shares the same SQLite
claims with background work. Home renders cached/inbox results instead of privately
checking 12 recently read books. Previously committed inbox updates render without
waiting for network; unobserved updates require catch-up. Doze, OEM restrictions
and force-stop can delay checks; force-stop recovery requires user interaction.

The SQLite queue is separate from reading history and Firebase library data.
Legacy manual timestamps seed newly queued jobs; completed pair checkpoints do not
rely on the full scan finishing. Changes preserve phase A's inbox-before-seen
ordering. Unit tests use actual SQLite for 70/200 jobs, abandoned leases, stale
owners, cooldowns, profiles, offline retry and budget-based continuation. Device
reboot/Doze/OEM behavior still requires Android-device validation.
